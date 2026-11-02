package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
)

// attribute_keys.source values.
const (
	sourceSpan     = 1
	sourceResource = 2
	sourceLog      = 3
)

type keySource struct {
	key    string
	source int
}

// Commit writes every batch in one transaction, recomputes the touched traces
// and advances the seq. Nothing is written when the batches are empty.
func (s *Store) Commit(batches []*Batch) (BatchResult, error) {
	var res BatchResult
	for _, b := range batches {
		res.Spans += len(b.Spans)
		res.Logs += len(b.Logs)
	}
	if res.Spans+res.Logs == 0 {
		return res, nil
	}
	seq := s.lastSeq + 1
	now := s.Now()
	ctx := context.Background()

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return res, err
	}
	defer tx.Rollback()

	newIDs := map[string]int64{}
	resourceID := func(r *Resource) (int64, error) {
		if id, ok := s.resourceIDs[r.Hash]; ok {
			return id, nil
		}
		if id, ok := newIDs[r.Hash]; ok {
			return id, nil
		}
		if _, err := tx.Stmt(s.stmts.insertResource).Exec(r.Hash, r.ServiceName, r.Attributes); err != nil {
			return 0, err
		}
		var id int64
		if err := tx.Stmt(s.stmts.selectResource).QueryRow(r.Hash).Scan(&id); err != nil {
			return 0, err
		}
		newIDs[r.Hash] = id
		return id, nil
	}

	services := map[string]bool{}
	keys := map[keySource]bool{}
	seenResource := map[*Resource]bool{}
	noteResource := func(r *Resource) {
		if seenResource[r] {
			return
		}
		seenResource[r] = true
		services[r.ServiceName] = true
		for _, k := range r.Keys {
			keys[keySource{k, sourceResource}] = true
		}
	}

	var touched []string
	touchedSet := map[string]bool{}

	upsertSpan := tx.Stmt(s.stmts.upsertSpan)
	insertLog := tx.Stmt(s.stmts.insertLog)
	for _, b := range batches {
		for i := range b.Spans {
			sp := &b.Spans[i]
			rid, err := resourceID(sp.Resource)
			if err != nil {
				return res, fmt.Errorf("resource: %w", err)
			}
			noteResource(sp.Resource)
			for _, k := range sp.AttrKeys {
				keys[keySource{k, sourceSpan}] = true
			}
			if _, err := upsertSpan.Exec(
				sp.TraceID, sp.SpanID, nullIfEmpty(sp.ParentSpanID), sp.Name, sp.Kind,
				sp.StartNs, sp.EndNs, max(0, sp.EndNs-sp.StartNs), sp.StatusCode, sp.StatusMessage,
				sp.Resource.ServiceName, rid, sp.ScopeName, sp.ScopeVersion,
				sp.Attributes, sp.Events, sp.Links,
				sp.DBSystem, sp.DBStatement, sp.HTTPMethod, sp.HTTPStatusCode, sp.HTTPRoute, sp.HTTPURL,
				now,
			); err != nil {
				return res, fmt.Errorf("span: %w", err)
			}
			if !touchedSet[sp.TraceID] {
				touchedSet[sp.TraceID] = true
				touched = append(touched, sp.TraceID)
			}
		}
		for i := range b.Logs {
			lg := &b.Logs[i]
			rid, err := resourceID(lg.Resource)
			if err != nil {
				return res, fmt.Errorf("resource: %w", err)
			}
			noteResource(lg.Resource)
			for _, k := range lg.AttrKeys {
				keys[keySource{k, sourceLog}] = true
			}
			t := lg.TimeNs
			if t == 0 {
				t = lg.ObservedNs
			}
			if t == 0 {
				t = now
			}
			if _, err := insertLog.Exec(
				t, lg.ObservedNs, lg.SeverityNumber, lg.SeverityText, lg.Resource.ServiceName, rid,
				lg.ScopeName, lg.Body, lg.Attributes, nullIfEmpty(lg.TraceID), nullIfEmpty(lg.SpanID),
				lg.EventName, now,
			); err != nil {
				return res, fmt.Errorf("log: %w", err)
			}
		}
	}

	upsertService := tx.Stmt(s.stmts.upsertService)
	for name := range services {
		if _, err := upsertService.Exec(name, now, now); err != nil {
			return res, fmt.Errorf("service: %w", err)
		}
	}
	upsertKey := tx.Stmt(s.stmts.upsertKey)
	for k := range keys {
		if _, err := upsertKey.Exec(k.key, k.source, now); err != nil {
			return res, fmt.Errorf("attribute key: %w", err)
		}
	}

	res.Traces = touched
	res.ErrorTraces = []string{}
	for _, id := range touched {
		becameError, err := s.recomputeTrace(tx, id, seq, now)
		if err != nil {
			return res, fmt.Errorf("trace %s: %w", id, err)
		}
		if becameError {
			res.ErrorTraces = append(res.ErrorTraces, id)
		}
	}
	if res.Traces == nil {
		res.Traces = []string{}
	}

	if _, err := tx.Stmt(s.stmts.setMeta).Exec("last_seq", strconv.FormatInt(seq, 10)); err != nil {
		return res, err
	}
	if err := tx.Commit(); err != nil {
		return res, err
	}
	for h, id := range newIDs {
		s.resourceIDs[h] = id
	}
	s.lastSeq = seq
	res.Seq = seq
	return res, nil
}

// recomputeTrace rebuilds one traces row from its spans, following the rules
// on the traces table in docs/schema.sql. It reports whether the trace's
// status became Error in this batch.
func (s *Store) recomputeTrace(tx *sql.Tx, traceID string, seq, now int64) (bool, error) {
	var start, end, count int64
	var errCount float64
	if err := tx.Stmt(s.stmts.traceAgg).QueryRow(traceID).Scan(&start, &end, &count, &errCount); err != nil {
		return false, err
	}

	var (
		rootID             sql.NullString
		service, name      string
		method, route      sql.NullString
		rootStatus, status int64
	)
	err := tx.Stmt(s.stmts.traceRoot).QueryRow(traceID).Scan(&rootID, &service, &name, &method, &route, &rootStatus)
	switch {
	case err == nil:
		status = rootStatus
	case isNoRows(err):
		// No root yet: describe the trace by its earliest span whose parent is missing.
		rootID = sql.NullString{}
		err = tx.Stmt(s.stmts.traceOrphan).QueryRow(traceID).Scan(&service, &name, &method, &route)
		if isNoRows(err) {
			err = tx.Stmt(s.stmts.traceEarliest).QueryRow(traceID).Scan(&service, &name, &method, &route)
		}
		if err != nil {
			return false, err
		}
		status = 0
	default:
		return false, err
	}
	if errCount > 0 {
		status = 2
	}

	var prev sql.NullInt64
	if err := tx.Stmt(s.stmts.tracePrev).QueryRow(traceID).Scan(&prev); err != nil && !isNoRows(err) {
		return false, err
	}

	if _, err := tx.Stmt(s.stmts.upsertTrace).Exec(
		traceID, rootID, service, Route(method.String, route.String, name),
		start, end, max(0, end-start), count, int64(errCount), status, seq, seq, now,
	); err != nil {
		return false, err
	}
	return status == 2 && (!prev.Valid || prev.Int64 != 2), nil
}

// Route is "<method> <route>" when both exist, else the route, else the span name.
func Route(method, route, name string) string {
	switch {
	case method != "" && route != "":
		return method + " " + route
	case route != "":
		return route
	default:
		return name
	}
}

func isNoRows(err error) bool { return errors.Is(err, sql.ErrNoRows) }
