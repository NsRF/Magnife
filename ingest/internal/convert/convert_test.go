package convert

import (
	"database/sql"
	"encoding/json"
	"math"
	"testing"

	"go.opentelemetry.io/collector/pdata/pcommon"
	"go.opentelemetry.io/collector/pdata/plog"
	"go.opentelemetry.io/collector/pdata/ptrace"
)

func TestAttributesJSON(t *testing.T) {
	m := pcommon.NewMap()
	m.PutStr("s", "a \"quoted\"\nline\x01 é \xff")
	m.PutInt("i", -42)
	m.PutDouble("d", 1.5)
	m.PutDouble("nan", math.NaN())
	m.PutBool("b", true)
	m.PutEmptyBytes("bytes").FromRaw([]byte{0, 1, 2})
	sl := m.PutEmptySlice("arr")
	sl.AppendEmpty().SetInt(1)
	sl.AppendEmpty().SetStr("two")
	kv := m.PutEmptyMap("obj")
	kv.PutStr("z", "last")
	kv.PutStr("a", "first")
	m.PutEmpty("nil")
	m.PutStr("dup", "old")
	got, keys := Attributes(m)
	got2, _ := Attributes(m)
	if got != got2 {
		t.Fatal("encoding is not stable")
	}
	want := `{"arr":[1,"two"],"b":true,"bytes":"AAEC","d":1.5,"dup":"old","i":-42,"nan":"NaN","nil":null,` +
		`"obj":{"a":"first","z":"last"},"s":"a \"quoted\"\nline\u0001 é �"}`
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
	if !json.Valid([]byte(got)) || len(keys) != 10 || keys[0] != "arr" {
		t.Fatalf("invalid JSON or keys %v", keys)
	}
	if a, _ := Attributes(pcommon.NewMap()); a != "{}" {
		t.Fatalf("empty map = %s", a)
	}
}

func TestRepeatedKeyKeepsLast(t *testing.T) {
	// The API cannot repeat a key, but the wire format can.
	body := `{"resourceSpans":[{"resource":{"attributes":[{"key":"k","value":{"stringValue":"first"}},` +
		`{"key":"k","value":{"stringValue":"last"}}]},"scopeSpans":[]}]}`
	td, err := (&ptrace.JSONUnmarshaler{}).UnmarshalTraces([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	attrs, keys := Attributes(td.ResourceSpans().At(0).Resource().Attributes())
	if attrs != `{"k":"last"}` || len(keys) != 1 {
		t.Fatalf("got %s %v", attrs, keys)
	}
}

func TestResourceHashIgnoresOrder(t *testing.T) {
	a, b := pcommon.NewResource(), pcommon.NewResource()
	a.Attributes().PutStr("service.name", "orders")
	a.Attributes().PutStr("host.name", "mac")
	b.Attributes().PutStr("host.name", "mac")
	b.Attributes().PutStr("service.name", "orders")
	ra, rb := Resource(a), Resource(b)
	if ra.Hash != rb.Hash || ra.ServiceName != "orders" || len(ra.Hash) != 64 {
		t.Fatalf("%+v vs %+v", ra, rb)
	}
	if r := Resource(pcommon.NewResource()); r.ServiceName != UnknownService {
		t.Fatalf("missing service.name -> %q", r.ServiceName)
	}
}

func newSpan(td ptrace.Traces) ptrace.Span {
	rs := td.ResourceSpans().AppendEmpty()
	rs.Resource().Attributes().PutStr("service.name", "svc")
	sp := rs.ScopeSpans().AppendEmpty().Spans().AppendEmpty()
	sp.SetTraceID(pcommon.TraceID{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16})
	sp.SetSpanID(pcommon.SpanID{0xa, 0xb, 0xc, 0xd, 0xe, 0xf, 1, 2})
	return sp
}

func TestPromotedColumnsOldAndNewSemconv(t *testing.T) {
	str := func(s string) sql.NullString { return sql.NullString{String: s, Valid: true} }
	cases := []struct {
		name  string
		attrs map[string]any
		check func(t *testing.T, sp spanCols)
	}{
		{"old names", map[string]any{"db.system": "postgresql", "db.statement": "SELECT 1", "http.method": "GET",
			"http.status_code": int64(200), "http.route": "/v1/orders", "http.url": "http://x/v1/orders?a=1"},
			func(t *testing.T, c spanCols) {
				want := spanCols{str("postgresql"), str("SELECT 1"), str("GET"), sql.NullInt64{Int64: 200, Valid: true}, str("/v1/orders"), str("http://x/v1/orders?a=1")}
				if c != want {
					t.Fatalf("got %+v", c)
				}
			}},
		{"new names", map[string]any{"db.system.name": "postgresql", "db.query.text": "SELECT 2", "http.request.method": "POST",
			"http.response.status_code": int64(500), "http.route": "/orders", "url.full": "http://localhost:5080/orders"},
			func(t *testing.T, c spanCols) {
				want := spanCols{str("postgresql"), str("SELECT 2"), str("POST"), sql.NullInt64{Int64: 500, Valid: true}, str("/orders"), str("http://localhost:5080/orders")}
				if c != want {
					t.Fatalf("got %+v", c)
				}
			}},
		{"url.path with url.query", map[string]any{"url.path": "/checkout", "url.query": "step=review", "http.response.status_code": "404"},
			func(t *testing.T, c spanCols) {
				if c.url != str("/checkout?step=review") || c.status != (sql.NullInt64{Int64: 404, Valid: true}) {
					t.Fatalf("got %+v", c)
				}
			}},
		{"url.path alone", map[string]any{"url.path": "/health"},
			func(t *testing.T, c spanCols) {
				if c.url != str("/health") {
					t.Fatalf("got %+v", c)
				}
			}},
		{"none", map[string]any{"rpc.system": "grpc"},
			func(t *testing.T, c spanCols) {
				if c != (spanCols{}) {
					t.Fatalf("got %+v", c)
				}
			}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			td := ptrace.NewTraces()
			sp := newSpan(td)
			for k, v := range c.attrs {
				switch v := v.(type) {
				case string:
					sp.Attributes().PutStr(k, v)
				case int64:
					sp.Attributes().PutInt(k, v)
				}
			}
			rows, _ := Traces(td)
			r := rows[0]
			c.check(t, spanCols{r.DBSystem, r.DBStatement, r.HTTPMethod, r.HTTPStatusCode, r.HTTPRoute, r.HTTPURL})
		})
	}
}

type spanCols struct {
	dbSystem, dbStatement, method sql.NullString
	status                        sql.NullInt64
	route, url                    sql.NullString
}

func TestSpanIDsEventsAndLinks(t *testing.T) {
	td := ptrace.NewTraces()
	sp := newSpan(td)
	sp.SetName("POST /payments")
	sp.SetKind(ptrace.SpanKindServer)
	sp.SetStartTimestamp(100)
	sp.SetEndTimestamp(50) // clock skew: duration clamps to 0 in the store
	sp.Status().SetCode(ptrace.StatusCodeError)
	sp.Status().SetMessage("boom")
	ev2 := sp.Events().AppendEmpty()
	ev2.SetName("later")
	ev2.SetTimestamp(300)
	ev := sp.Events().AppendEmpty()
	ev.SetName("exception")
	ev.SetTimestamp(200)
	ev.Attributes().PutStr("exception.type", "System.InvalidOperationException")
	ev.Attributes().PutStr("exception.stacktrace", "line1\n   at line2")
	l := sp.Links().AppendEmpty()
	l.SetTraceID(pcommon.TraceID{0xff, 15: 1})
	l.Attributes().PutStr("link.kind", "retry")

	// A span with all-zero ids is rejected; one with a zero parent is a root.
	bad := td.ResourceSpans().At(0).ScopeSpans().At(0).Spans().AppendEmpty()
	bad.SetName("no ids")

	rows, rejected := Traces(td)
	if rejected != 1 || len(rows) != 1 {
		t.Fatalf("rows=%d rejected=%d", len(rows), rejected)
	}
	r := rows[0]
	if r.TraceID != "0102030405060708090a0b0c0d0e0f10" || r.SpanID != "0a0b0c0d0e0f0102" || r.ParentSpanID != "" {
		t.Fatalf("ids %q %q %q", r.TraceID, r.SpanID, r.ParentSpanID)
	}
	if r.Kind != 2 || r.StatusCode != 2 || r.StatusMessage != "boom" || r.Resource.ServiceName != "svc" {
		t.Fatalf("%+v", r)
	}
	wantEvents := `[{"time_ns":200,"name":"exception","attributes":{"exception.stacktrace":"line1\n   at line2","exception.type":"System.InvalidOperationException"}},` +
		`{"time_ns":300,"name":"later","attributes":{}}]`
	if r.Events != wantEvents {
		t.Fatalf("events\n got %s\nwant %s", r.Events, wantEvents)
	}
	wantLinks := `[{"trace_id":"ff000000000000000000000000000001","span_id":null,"attributes":{"link.kind":"retry"}}]`
	if r.Links != wantLinks {
		t.Fatalf("links\n got %s\nwant %s", r.Links, wantLinks)
	}
}

func TestLogs(t *testing.T) {
	ld := plog.NewLogs()
	rl := ld.ResourceLogs().AppendEmpty()
	rl.Resource().Attributes().PutStr("service.name", "web")
	sl := rl.ScopeLogs().AppendEmpty()
	sl.Scope().SetName("@opentelemetry/instrumentation-pino")
	a := sl.LogRecords().AppendEmpty()
	a.SetTimestamp(10)
	a.SetObservedTimestamp(11)
	a.SetSeverityNumber(plog.SeverityNumberWarn)
	a.SetSeverityText("warn")
	a.Body().SetStr("plain text")
	a.SetTraceID(pcommon.TraceID{15: 1})
	a.SetSpanID(pcommon.SpanID{7: 2})
	a.SetEventName("app.checkout")
	b := sl.LogRecords().AppendEmpty()
	b.SetObservedTimestamp(20)
	b.Body().SetEmptyMap().PutStr("msg", "server started")

	rows := Logs(ld)
	if len(rows) != 2 {
		t.Fatal(len(rows))
	}
	if r := rows[0]; r.Body != "plain text" || r.TraceID != "00000000000000000000000000000001" ||
		r.SpanID != "0000000000000002" || r.SeverityNumber != 13 || r.EventName != "app.checkout" || r.ScopeName == "" {
		t.Fatalf("%+v", r)
	}
	if r := rows[1]; r.Body != `{"msg":"server started"}` || r.TraceID != "" || r.SpanID != "" || r.TimeNs != 0 || r.ObservedNs != 20 {
		t.Fatalf("%+v", r)
	}
}
