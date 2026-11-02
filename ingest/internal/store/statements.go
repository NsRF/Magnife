package store

import (
	"database/sql"
	"fmt"
)

// statements are prepared once on the single connection and bound to each
// transaction with tx.Stmt.
type statements struct {
	insertResource *sql.Stmt
	selectResource *sql.Stmt
	upsertService  *sql.Stmt
	upsertSpan     *sql.Stmt
	insertLog      *sql.Stmt
	upsertKey      *sql.Stmt
	setMeta        *sql.Stmt

	traceAgg      *sql.Stmt
	traceRoot     *sql.Stmt
	traceOrphan   *sql.Stmt
	traceEarliest *sql.Stmt
	tracePrev     *sql.Stmt
	upsertTrace   *sql.Stmt

	pruneSelect *sql.Stmt
	pruneSpans  *sql.Stmt
	pruneLogs   *sql.Stmt
	pruneTraces *sql.Stmt
	pruneOldLog *sql.Stmt
}

const spanColumns = `trace_id, span_id, parent_span_id, name, kind, start_ns, end_ns, duration_ns,
	status_code, status_message, service_name, resource_id, scope_name, scope_version,
	attributes, events, links, db_system, db_statement, http_method, http_status_code,
	http_route, http_url, received_ns`

func (st *statements) prepare(db *sql.DB) error {
	list := []struct {
		dst **sql.Stmt
		sql string
	}{
		{&st.insertResource, `INSERT INTO resources (hash, service_name, attributes) VALUES (?, ?, ?)
			ON CONFLICT (hash) DO NOTHING`},
		{&st.selectResource, `SELECT id FROM resources WHERE hash = ?`},
		{&st.upsertService, `INSERT INTO services (name, first_seen_ns, last_seen_ns) VALUES (?, ?, ?)
			ON CONFLICT (name) DO UPDATE SET last_seen_ns = MAX(last_seen_ns, excluded.last_seen_ns)`},
		{&st.upsertSpan, `INSERT INTO spans (` + spanColumns + `)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT (trace_id, span_id) DO UPDATE SET
				parent_span_id = excluded.parent_span_id, name = excluded.name, kind = excluded.kind,
				start_ns = excluded.start_ns, end_ns = excluded.end_ns, duration_ns = excluded.duration_ns,
				status_code = excluded.status_code, status_message = excluded.status_message,
				service_name = excluded.service_name, resource_id = excluded.resource_id,
				scope_name = excluded.scope_name, scope_version = excluded.scope_version,
				attributes = excluded.attributes, events = excluded.events, links = excluded.links,
				db_system = excluded.db_system, db_statement = excluded.db_statement,
				http_method = excluded.http_method, http_status_code = excluded.http_status_code,
				http_route = excluded.http_route, http_url = excluded.http_url,
				received_ns = excluded.received_ns`},
		{&st.insertLog, `INSERT INTO logs (time_ns, observed_ns, severity_number, severity_text,
			service_name, resource_id, scope_name, body, attributes, trace_id, span_id, event_name, received_ns)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`},
		{&st.upsertKey, `INSERT INTO attribute_keys (key, source, last_seen_ns) VALUES (?, ?, ?)
			ON CONFLICT (key, source) DO UPDATE SET last_seen_ns = excluded.last_seen_ns`},
		{&st.setMeta, `INSERT INTO meta (key, value) VALUES (?, ?)
			ON CONFLICT (key) DO UPDATE SET value = excluded.value`},

		{&st.traceAgg, `SELECT MIN(start_ns), MAX(end_ns), COUNT(*), TOTAL(status_code = 2)
			FROM spans WHERE trace_id = ?`},
		{&st.traceRoot, `SELECT span_id, service_name, name, http_method, http_route, status_code
			FROM spans WHERE trace_id = ? AND parent_span_id IS NULL
			ORDER BY start_ns, id LIMIT 1`},
		// The earliest-starting span whose parent is not in the trace.
		{&st.traceOrphan, `SELECT s.service_name, s.name, s.http_method, s.http_route
			FROM spans s WHERE s.trace_id = ?1 AND NOT EXISTS (
				SELECT 1 FROM spans p WHERE p.trace_id = ?1 AND p.span_id = s.parent_span_id)
			ORDER BY s.start_ns, s.id LIMIT 1`},
		// Only reached when parents form a cycle.
		{&st.traceEarliest, `SELECT service_name, name, http_method, http_route
			FROM spans WHERE trace_id = ? ORDER BY start_ns, id LIMIT 1`},
		{&st.tracePrev, `SELECT status FROM traces WHERE trace_id = ?`},
		{&st.upsertTrace, `INSERT INTO traces (trace_id, root_span_id, root_service, route, start_ns, end_ns,
				duration_ns, span_count, error_count, status, first_seq, updated_seq, received_ns)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT (trace_id) DO UPDATE SET
				root_span_id = excluded.root_span_id, root_service = excluded.root_service,
				route = excluded.route, start_ns = excluded.start_ns, end_ns = excluded.end_ns,
				duration_ns = excluded.duration_ns, span_count = excluded.span_count,
				error_count = excluded.error_count, status = excluded.status,
				updated_seq = excluded.updated_seq, received_ns = excluded.received_ns`},

		{&st.pruneSelect, `SELECT trace_id FROM traces WHERE received_ns < ? LIMIT ?`},
		{&st.pruneSpans, `DELETE FROM spans WHERE trace_id IN (SELECT value FROM json_each(?))`},
		{&st.pruneLogs, `DELETE FROM logs WHERE trace_id IN (SELECT value FROM json_each(?))`},
		{&st.pruneTraces, `DELETE FROM traces WHERE trace_id IN (SELECT value FROM json_each(?))`},
		{&st.pruneOldLog, `DELETE FROM logs WHERE id IN (SELECT id FROM logs WHERE received_ns < ? LIMIT ?)`},
	}
	for _, s := range list {
		stmt, err := db.Prepare(s.sql)
		if err != nil {
			return fmt.Errorf("prepare %q: %w", s.sql, err)
		}
		*s.dst = stmt
	}
	return nil
}

func (st *statements) close() {
	for _, s := range []*sql.Stmt{st.insertResource, st.selectResource, st.upsertService, st.upsertSpan,
		st.insertLog, st.upsertKey, st.setMeta, st.traceAgg, st.traceRoot, st.traceOrphan, st.traceEarliest,
		st.tracePrev, st.upsertTrace, st.pruneSelect, st.pruneSpans, st.pruneLogs, st.pruneTraces, st.pruneOldLog} {
		if s != nil {
			s.Close()
		}
	}
}
