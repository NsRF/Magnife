package convert

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"slices"
	"strconv"

	"go.opentelemetry.io/collector/pdata/pcommon"
	"go.opentelemetry.io/collector/pdata/plog"
	"go.opentelemetry.io/collector/pdata/ptrace"

	"magnife/ingest/internal/store"
)

// UnknownService is resources.service_name when service.name is missing.
const UnknownService = "unknown_service"

// Resource encodes a resource and hashes its canonical attributes JSON.
func Resource(r pcommon.Resource) *store.Resource {
	attrs, keys := Attributes(r.Attributes())
	sum := sha256.Sum256([]byte(attrs))
	name := UnknownService
	if v, ok := r.Attributes().Get("service.name"); ok && v.AsString() != "" {
		name = v.AsString()
	}
	return &store.Resource{Hash: hex.EncodeToString(sum[:]), ServiceName: name, Attributes: attrs, Keys: keys}
}

func traceID(id pcommon.TraceID) string {
	if id.IsEmpty() {
		return ""
	}
	return hex.EncodeToString(id[:])
}

func spanID(id pcommon.SpanID) string {
	if id.IsEmpty() {
		return ""
	}
	return hex.EncodeToString(id[:])
}

// Traces converts every span. Spans without a trace id or span id cannot be
// stored (both columns are NOT NULL) and are counted as rejected.
func Traces(td ptrace.Traces) (spans []store.Span, rejected int) {
	spans = make([]store.Span, 0, td.SpanCount())
	rss := td.ResourceSpans()
	for i := 0; i < rss.Len(); i++ {
		rs := rss.At(i)
		res := Resource(rs.Resource())
		sss := rs.ScopeSpans()
		for j := 0; j < sss.Len(); j++ {
			ss := sss.At(j)
			scope := ss.Scope()
			list := ss.Spans()
			for k := 0; k < list.Len(); k++ {
				sp := list.At(k)
				tid, sid := traceID(sp.TraceID()), spanID(sp.SpanID())
				if tid == "" || sid == "" {
					rejected++
					continue
				}
				attrs, keys := Attributes(sp.Attributes())
				row := store.Span{
					Resource:      res,
					TraceID:       tid,
					SpanID:        sid,
					ParentSpanID:  spanID(sp.ParentSpanID()),
					Name:          sp.Name(),
					Kind:          int32(sp.Kind()),
					StartNs:       int64(sp.StartTimestamp()),
					EndNs:         int64(sp.EndTimestamp()),
					StatusCode:    int32(sp.Status().Code()),
					StatusMessage: sp.Status().Message(),
					ScopeName:     scope.Name(),
					ScopeVersion:  scope.Version(),
					Attributes:    attrs,
					AttrKeys:      keys,
					Events:        events(sp.Events()),
					Links:         links(sp.Links()),
				}
				promote(&row, sp.Attributes())
				spans = append(spans, row)
			}
		}
	}
	return spans, rejected
}

// events encodes span events in time order.
func events(evs ptrace.SpanEventSlice) string {
	if evs.Len() == 0 {
		return "[]"
	}
	order := make([]int, evs.Len())
	for i := range order {
		order[i] = i
	}
	slices.SortStableFunc(order, func(a, b int) int {
		ta, tb := evs.At(a).Timestamp(), evs.At(b).Timestamp()
		switch {
		case ta < tb:
			return -1
		case ta > tb:
			return 1
		}
		return 0
	})
	b := []byte{'['}
	for n, i := range order {
		ev := evs.At(i)
		if n > 0 {
			b = append(b, ',')
		}
		b = append(b, `{"time_ns":`...)
		b = strconv.AppendUint(b, uint64(ev.Timestamp()), 10)
		b = append(b, `,"name":`...)
		b = appendString(b, ev.Name())
		b = append(b, `,"attributes":`...)
		b = appendMap(b, ev.Attributes())
		b = append(b, '}')
	}
	return string(append(b, ']'))
}

// links encodes span links; all-zero ids become null.
func links(ls ptrace.SpanLinkSlice) string {
	if ls.Len() == 0 {
		return "[]"
	}
	b := []byte{'['}
	for i := 0; i < ls.Len(); i++ {
		l := ls.At(i)
		if i > 0 {
			b = append(b, ',')
		}
		b = append(b, `{"trace_id":`...)
		b = appendID(b, traceID(l.TraceID()))
		b = append(b, `,"span_id":`...)
		b = appendID(b, spanID(l.SpanID()))
		b = append(b, `,"attributes":`...)
		b = appendMap(b, l.Attributes())
		b = append(b, '}')
	}
	return string(append(b, ']'))
}

func appendID(b []byte, id string) []byte {
	if id == "" {
		return append(b, "null"...)
	}
	return appendString(b, id)
}

// promote copies the attributes the app's detectors and list read into
// columns, accepting old and new semantic-convention names.
func promote(row *store.Span, m pcommon.Map) {
	row.DBSystem = str(m, "db.system", "db.system.name")
	row.DBStatement = str(m, "db.statement", "db.query.text")
	row.HTTPMethod = str(m, "http.method", "http.request.method")
	row.HTTPRoute = str(m, "http.route")
	row.HTTPStatusCode = integer(m, "http.status_code", "http.response.status_code")
	row.HTTPURL = str(m, "http.url", "url.full")
	if !row.HTTPURL.Valid {
		if p := str(m, "url.path"); p.Valid {
			if q := str(m, "url.query"); q.Valid {
				p.String += "?" + q.String
			}
			row.HTTPURL = p
		}
	}
}

// str returns the first present, non-empty attribute among keys as text.
func str(m pcommon.Map, keys ...string) sql.NullString {
	for _, k := range keys {
		if v, ok := m.Get(k); ok {
			if s := v.AsString(); s != "" {
				return sql.NullString{String: s, Valid: true}
			}
		}
	}
	return sql.NullString{}
}

// integer returns the first attribute among keys that holds an integer
// (as an int, a whole double or a numeric string).
func integer(m pcommon.Map, keys ...string) sql.NullInt64 {
	for _, k := range keys {
		v, ok := m.Get(k)
		if !ok {
			continue
		}
		switch v.Type() {
		case pcommon.ValueTypeInt:
			return sql.NullInt64{Int64: v.Int(), Valid: true}
		case pcommon.ValueTypeDouble:
			if f := v.Double(); f == float64(int64(f)) {
				return sql.NullInt64{Int64: int64(f), Valid: true}
			}
		case pcommon.ValueTypeStr:
			if n, err := strconv.ParseInt(v.Str(), 10, 64); err == nil {
				return sql.NullInt64{Int64: n, Valid: true}
			}
		}
	}
	return sql.NullInt64{}
}

// Logs converts every log record. The time falls back to the observed time
// when time_unix_nano is 0 (the store applies the fallback).
func Logs(ld plog.Logs) []store.Log {
	out := make([]store.Log, 0, ld.LogRecordCount())
	rls := ld.ResourceLogs()
	for i := 0; i < rls.Len(); i++ {
		rl := rls.At(i)
		res := Resource(rl.Resource())
		sls := rl.ScopeLogs()
		for j := 0; j < sls.Len(); j++ {
			sl := sls.At(j)
			scope := sl.Scope().Name()
			recs := sl.LogRecords()
			for k := 0; k < recs.Len(); k++ {
				lr := recs.At(k)
				attrs, keys := Attributes(lr.Attributes())
				out = append(out, store.Log{
					Resource:       res,
					TimeNs:         int64(lr.Timestamp()),
					ObservedNs:     int64(lr.ObservedTimestamp()),
					SeverityNumber: int32(lr.SeverityNumber()),
					SeverityText:   lr.SeverityText(),
					ScopeName:      scope,
					Body:           body(lr.Body()),
					Attributes:     attrs,
					AttrKeys:       keys,
					TraceID:        traceID(lr.TraceID()),
					SpanID:         spanID(lr.SpanID()),
					EventName:      lr.EventName(),
				})
			}
		}
	}
	return out
}

// body keeps a string body as is and encodes any other body as JSON.
func body(v pcommon.Value) string {
	switch v.Type() {
	case pcommon.ValueTypeStr:
		return v.Str()
	case pcommon.ValueTypeEmpty:
		return ""
	default:
		return ValueJSON(v)
	}
}
