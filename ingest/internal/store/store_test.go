package store

import (
	"database/sql"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestSchemaCopyMatchesDocs(t *testing.T) {
	docs, err := os.ReadFile(filepath.Join("..", "..", "..", "docs", "schema.sql"))
	if err != nil {
		t.Fatal(err)
	}
	if string(docs) != SchemaSQL {
		t.Fatal("ingest/internal/store/schema.sql differs from docs/schema.sql; copy docs/schema.sql over it")
	}
}

// tmpDir is a fresh directory under /tmp, where test databases belong.
func tmpDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "magnife-store-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func openTest(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(tmpDir(t), "sub", "magnife.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

var testResource = &Resource{Hash: "h1", ServiceName: "checkout-api", Attributes: `{"service.name":"checkout-api"}`, Keys: []string{"service.name"}}
var ordersResource = &Resource{Hash: "h2", ServiceName: "orders", Attributes: `{"service.name":"orders"}`, Keys: []string{"service.name"}}

func span(trace, id, parent, name string, start, end int64, status int32) Span {
	return Span{Resource: testResource, TraceID: trace, SpanID: id, ParentSpanID: parent, Name: name,
		Kind: 2, StartNs: start, EndNs: end, StatusCode: status, Attributes: "{}", Events: "[]", Links: "[]"}
}

type traceRow struct {
	Root        sql.NullString
	Service     string
	Route       string
	Start, End  int64
	Duration    int64
	Spans, Errs int64
	Status      int64
	FirstSeq    int64
	UpdatedSeq  int64
}

func getTrace(t *testing.T, s *Store, id string) traceRow {
	t.Helper()
	var r traceRow
	err := s.db.QueryRow(`SELECT root_span_id, root_service, route, start_ns, end_ns, duration_ns, span_count,
		error_count, status, first_seq, updated_seq FROM traces WHERE trace_id = ?`, id).
		Scan(&r.Root, &r.Service, &r.Route, &r.Start, &r.End, &r.Duration, &r.Spans, &r.Errs, &r.Status, &r.FirstSeq, &r.UpdatedSeq)
	if err != nil {
		t.Fatalf("trace %s: %v", id, err)
	}
	return r
}

func commit(t *testing.T, s *Store, b ...*Batch) BatchResult {
	t.Helper()
	res, err := s.Commit(b)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func TestOpenAppliesSchemaAndPragmas(t *testing.T) {
	s := openTest(t)
	var mode string
	var version, fk int
	s.db.QueryRow("PRAGMA journal_mode").Scan(&mode)
	s.db.QueryRow("PRAGMA user_version").Scan(&version)
	s.db.QueryRow("PRAGMA foreign_keys").Scan(&fk)
	var sync int
	s.db.QueryRow("PRAGMA synchronous").Scan(&sync)
	if mode != "wal" || version != 1 || fk != 0 || sync != 1 {
		t.Fatalf("journal_mode=%s user_version=%d foreign_keys=%d synchronous=%d", mode, version, fk, sync)
	}
	var v string
	if err := s.db.QueryRow("SELECT value FROM meta WHERE key = 'schema_version'").Scan(&v); err != nil || v != "1" {
		t.Fatalf("schema_version = %q, %v", v, err)
	}
}

func TestSeqContinuesAcrossReopen(t *testing.T) {
	path := filepath.Join(tmpDir(t), "m.sqlite")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	commit(t, s, &Batch{Spans: []Span{span("t1", "a", "", "root", 1, 2, 0)}})
	commit(t, s, &Batch{Spans: []Span{span("t1", "b", "a", "child", 1, 2, 0)}})
	s.Close()
	s, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if res := commit(t, s, &Batch{Spans: []Span{span("t2", "a", "", "root", 1, 2, 0)}}); res.Seq != 3 {
		t.Fatalf("seq after reopen = %d, want 3", res.Seq)
	}
}

func TestCommitResultAndErrorTraces(t *testing.T) {
	s := openTest(t)
	res := commit(t, s, &Batch{Spans: []Span{
		span("t1", "a", "", "GET /", 100, 200, 0),
		span("t2", "b", "", "POST /pay", 100, 300, 0),
		span("t2", "c", "b", "INSERT", 150, 250, 2),
	}, Logs: []Log{{Resource: testResource, TimeNs: 5, Body: "hi", Attributes: "{}"}}})
	want := BatchResult{Seq: 1, Spans: 3, Logs: 1, Traces: []string{"t1", "t2"}, ErrorTraces: []string{"t2"}}
	if !reflect.DeepEqual(res, want) {
		t.Fatalf("got %+v, want %+v", res, want)
	}
	// Already Error: not listed again. t1 becomes Error now.
	res = commit(t, s, &Batch{Spans: []Span{
		span("t2", "d", "b", "SELECT", 160, 170, 2),
		span("t1", "e", "a", "SELECT", 120, 130, 2),
	}})
	if res.Seq != 2 || !reflect.DeepEqual(res.ErrorTraces, []string{"t1"}) {
		t.Fatalf("second batch: %+v", res)
	}
	// A logs-only batch still commits with an empty traces list.
	res = commit(t, s, &Batch{Logs: []Log{{Resource: testResource, Body: "x", Attributes: "{}"}}})
	if res.Seq != 3 || res.Traces == nil || len(res.Traces) != 0 || res.ErrorTraces == nil {
		t.Fatalf("logs-only batch: %+v", res)
	}
	if res, _ := s.Commit(nil); res.Seq != 0 || s.LastSeq() != 3 {
		t.Fatal("empty commit must not take a seq")
	}
	var last string
	s.db.QueryRow("SELECT value FROM meta WHERE key = 'last_seq'").Scan(&last)
	if last != "3" {
		t.Fatalf("meta last_seq = %s", last)
	}
}

func TestTraceRecomputeLateSpansAndMissingParent(t *testing.T) {
	s := openTest(t)
	// Batch 1: a child whose parent ("root") has not arrived, plus a grandchild.
	child := span("t", "c1", "root", "SELECT orders", 200, 300, 0)
	child.Resource = ordersResource
	commit(t, s, &Batch{Spans: []Span{child, span("t", "g1", "c1", "inner", 210, 220, 0)}})
	r := getTrace(t, s, "t")
	if r.Root.Valid || r.Service != "orders" || r.Route != "SELECT orders" || r.Status != 0 || r.Spans != 2 ||
		r.Start != 200 || r.End != 300 || r.FirstSeq != 1 || r.UpdatedSeq != 1 {
		t.Fatalf("before root: %+v", r)
	}

	// Batch 2: an earlier orphan with a different service takes over as the
	// description until the root arrives.
	orphan := span("t", "o1", "never-arrives", "GET /v1/orders", 150, 160, 1)
	orphan.HTTPMethod = sql.NullString{String: "GET", Valid: true}
	orphan.HTTPRoute = sql.NullString{String: "/v1/orders", Valid: true}
	commit(t, s, &Batch{Spans: []Span{orphan}})
	r = getTrace(t, s, "t")
	if r.Root.Valid || r.Service != "checkout-api" || r.Route != "GET /v1/orders" || r.Status != 0 {
		t.Fatalf("orphan: %+v", r)
	}

	// Batch 3: the root arrives late.
	root := span("t", "root", "", "POST /orders", 100, 400, 1)
	root.HTTPMethod = sql.NullString{String: "POST", Valid: true}
	root.HTTPRoute = sql.NullString{String: "/orders", Valid: true}
	commit(t, s, &Batch{Spans: []Span{root}})
	r = getTrace(t, s, "t")
	want := traceRow{Root: sql.NullString{String: "root", Valid: true}, Service: "checkout-api", Route: "POST /orders",
		Start: 100, End: 400, Duration: 300, Spans: 4, Errs: 0, Status: 1, FirstSeq: 1, UpdatedSeq: 3}
	if r != want {
		t.Fatalf("after root:\n got %+v\nwant %+v", r, want)
	}

	// Batch 4: a span resent with an error replaces the old row.
	again := span("t", "g1", "c1", "inner", 210, 450, 2)
	res := commit(t, s, &Batch{Spans: []Span{again}})
	r = getTrace(t, s, "t")
	if r.Spans != 4 || r.Errs != 1 || r.Status != 2 || r.End != 450 || r.UpdatedSeq != 4 || r.FirstSeq != 1 {
		t.Fatalf("after resend: %+v", r)
	}
	if !reflect.DeepEqual(res.ErrorTraces, []string{"t"}) {
		t.Fatalf("error_traces = %v", res.ErrorTraces)
	}
	var n int
	s.db.QueryRow("SELECT COUNT(*) FROM spans WHERE trace_id = 't' AND span_id = 'g1'").Scan(&n)
	if n != 1 {
		t.Fatalf("resent span stored %d times", n)
	}
}

func TestRouteAndStatusRules(t *testing.T) {
	cases := []struct {
		name          string
		method, route string
		spanName      string
		rootStatus    int32
		childStatus   int32
		wantRoute     string
		wantStatus    int64
	}{
		{"method and route", "GET", "/orders/{id}", "GET /orders/{id}", 0, 0, "GET /orders/{id}", 0},
		{"route only", "", "/orders", "handler", 1, 0, "/orders", 1},
		{"method only uses name", "GET", "", "GET", 1, 1, "GET", 1},
		{"neither", "", "", "inventory.reconcile", 0, 0, "inventory.reconcile", 0},
		{"error child wins over ok root", "POST", "/pay", "POST /pay", 1, 2, "POST /pay", 2},
		{"error root", "", "", "job", 2, 0, "job", 2},
	}
	s := openTest(t)
	for i, c := range cases {
		id := string(rune('a' + i))
		root := span(id, "r", "", c.spanName, 0, 10, c.rootStatus)
		root.HTTPMethod = sql.NullString{String: c.method, Valid: c.method != ""}
		root.HTTPRoute = sql.NullString{String: c.route, Valid: c.route != ""}
		commit(t, s, &Batch{Spans: []Span{root, span(id, "k", "r", "child", 1, 2, c.childStatus)}})
		r := getTrace(t, s, id)
		if r.Route != c.wantRoute || r.Status != c.wantStatus {
			t.Errorf("%s: route %q status %d, want %q %d", c.name, r.Route, r.Status, c.wantRoute, c.wantStatus)
		}
	}
}

func TestLogsWithAndWithoutTraceID(t *testing.T) {
	s := openTest(t)
	s.Now = func() int64 { return 9_000 }
	commit(t, s, &Batch{Logs: []Log{
		{Resource: testResource, TimeNs: 100, ObservedNs: 110, SeverityNumber: 17, SeverityText: "Error",
			Body: "failed", Attributes: `{"k":1}`, AttrKeys: []string{"k"}, TraceID: "t1", SpanID: "s1", EventName: "e"},
		{Resource: testResource, TimeNs: 0, ObservedNs: 220, SeverityNumber: 9, Body: "no trace", Attributes: "{}"},
		{Resource: ordersResource, Body: "no times", Attributes: "{}"},
	}})
	rows, err := s.db.Query(`SELECT time_ns, observed_ns, service_name, trace_id, span_id, received_ns FROM logs ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var got []string
	for rows.Next() {
		var tm, obs, recv int64
		var svc string
		var tid, sid sql.NullString
		rows.Scan(&tm, &obs, &svc, &tid, &sid, &recv)
		got = append(got, strings.Join([]string{i64(tm), i64(obs), svc, tid.String, sid.String, i64(recv)}, "|"))
	}
	want := []string{"100|110|checkout-api|t1|s1|9000", "220|220|checkout-api|||9000", "9000|0|orders|||9000"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("logs:\n got %v\nwant %v", got, want)
	}
	var nulls int
	s.db.QueryRow("SELECT COUNT(*) FROM logs WHERE trace_id IS NULL AND span_id IS NULL").Scan(&nulls)
	if nulls != 2 {
		t.Fatalf("logs without trace id stored with NULL ids: %d, want 2", nulls)
	}
	var services, keys int
	s.db.QueryRow("SELECT COUNT(*) FROM services").Scan(&services)
	s.db.QueryRow("SELECT COUNT(*) FROM attribute_keys WHERE (key = 'k' AND source = 3) OR (key = 'service.name' AND source = 2)").Scan(&keys)
	if services != 2 || keys != 2 {
		t.Fatalf("services=%d keys=%d", services, keys)
	}
	var traces int
	s.db.QueryRow("SELECT COUNT(*) FROM traces").Scan(&traces)
	if traces != 0 {
		t.Fatal("logs must not create trace rows")
	}
}

func i64(n int64) string { return strconv.FormatInt(n, 10) }

func TestResourcesAndServices(t *testing.T) {
	s := openTest(t)
	s.Now = func() int64 { return 1000 }
	commit(t, s, &Batch{Spans: []Span{span("t", "a", "", "x", 0, 1, 0)}})
	s.Now = func() int64 { return 2000 }
	sp := span("t", "b", "a", "y", 0, 1, 0)
	sp.Resource = ordersResource
	commit(t, s, &Batch{Spans: []Span{sp, span("t", "c", "a", "z", 0, 1, 0)}})
	var resources int
	s.db.QueryRow("SELECT COUNT(*) FROM resources").Scan(&resources)
	var first, last int64
	s.db.QueryRow("SELECT first_seen_ns, last_seen_ns FROM services WHERE name = 'checkout-api'").Scan(&first, &last)
	if resources != 2 || first != 1000 || last != 2000 {
		t.Fatalf("resources=%d first=%d last=%d", resources, first, last)
	}
	var mismatched int
	s.db.QueryRow("SELECT COUNT(*) FROM spans s JOIN resources r ON r.id = s.resource_id WHERE r.service_name != s.service_name").Scan(&mismatched)
	if mismatched != 0 {
		t.Fatal("span service_name differs from its resource")
	}
}

func TestPruneInChunks(t *testing.T) {
	s := openTest(t)
	old, recent := int64(1_000*time.Second), int64(10_000*time.Second)
	s.Now = func() int64 { return old }
	var spans []Span
	var logs []Log
	for i := range 1200 {
		id := "old" + i64(int64(i))
		spans = append(spans, span(id, "r", "", "x", 0, 1, 0), span(id, "c", "r", "y", 0, 1, 0))
		logs = append(logs, Log{Resource: testResource, Body: "l", Attributes: "{}", TraceID: id})
	}
	logs = append(logs, Log{Resource: testResource, Body: "old, no trace", Attributes: "{}"})
	commit(t, s, &Batch{Spans: spans, Logs: logs})
	s.Now = func() int64 { return recent }
	commit(t, s, &Batch{
		Spans: []Span{span("new", "r", "", "x", 0, 1, 0)},
		Logs:  []Log{{Resource: testResource, Body: "new", Attributes: "{}", TraceID: "new"}},
	})

	cutoff := recent - int64(3600*time.Second)
	var total PruneResult
	chunks := 0
	for {
		res, done, err := s.PruneChunk(cutoff, 3600)
		if err != nil {
			t.Fatal(err)
		}
		chunks++
		total.Add(res)
		if done {
			break
		}
	}
	if chunks != 3 || total != (PruneResult{Traces: 1200, Spans: 2400, Logs: 1201}) {
		t.Fatalf("chunks=%d total=%+v", chunks, total)
	}
	var traces, spansLeft, logsLeft int
	s.db.QueryRow("SELECT COUNT(*) FROM traces").Scan(&traces)
	s.db.QueryRow("SELECT COUNT(*) FROM spans").Scan(&spansLeft)
	s.db.QueryRow("SELECT COUNT(*) FROM logs").Scan(&logsLeft)
	if traces != 1 || spansLeft != 1 || logsLeft != 1 {
		t.Fatalf("left traces=%d spans=%d logs=%d", traces, spansLeft, logsLeft)
	}
	var ret string
	s.db.QueryRow("SELECT value FROM meta WHERE key = 'retention_s'").Scan(&ret)
	if ret != "3600" {
		t.Fatalf("retention_s = %q", ret)
	}
}

// events records writer events for tests.
type events struct {
	mu      sync.Mutex
	batches []BatchResult
	pruned  []PruneResult
	errs    []error
	notify  chan struct{}
}

func newEvents() *events { return &events{notify: make(chan struct{}, 100)} }

func (e *events) Batch(r BatchResult) {
	e.mu.Lock()
	e.batches = append(e.batches, r)
	e.mu.Unlock()
	e.notify <- struct{}{}
}
func (e *events) Pruned(r PruneResult) {
	e.mu.Lock()
	e.pruned = append(e.pruned, r)
	e.mu.Unlock()
	e.notify <- struct{}{}
}
func (e *events) Error(err error) {
	e.mu.Lock()
	e.errs = append(e.errs, err)
	e.mu.Unlock()
}

func (e *events) wait(t *testing.T) {
	t.Helper()
	select {
	case <-e.notify:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for a writer event")
	}
}

func TestWriterBatchesBySizeAndTime(t *testing.T) {
	s := openTest(t)
	ev := newEvents()
	w := NewWriter(s, 86400, ev)
	w.MaxRecords = 10
	w.MaxDelay = 200 * time.Millisecond
	w.Start()
	defer w.Close()
	ctx := t.Context()

	// Ten records in three submits reach MaxRecords: one commit, at once.
	began := time.Now()
	for i, n := range []int{3, 3, 4} {
		var b Batch
		for j := range n {
			b.Spans = append(b.Spans, span("size", i64(int64(i*10+j)), "", "x", 0, 1, 0))
		}
		if err := w.Submit(ctx, &b); err != nil {
			t.Fatal(err)
		}
	}
	ev.wait(t)
	if d := time.Since(began); d > 150*time.Millisecond {
		t.Fatalf("size-triggered commit took %v", d)
	}

	// Two records wait for MaxDelay.
	began = time.Now()
	w.Submit(ctx, &Batch{Spans: []Span{span("time", "a", "", "x", 0, 1, 0), span("time", "b", "a", "y", 0, 1, 0)}})
	ev.wait(t)
	if d := time.Since(began); d < 180*time.Millisecond {
		t.Fatalf("time-triggered commit after %v, want about 200ms", d)
	}
	ev.mu.Lock()
	defer ev.mu.Unlock()
	if len(ev.batches) != 2 || ev.batches[0].Spans != 10 || ev.batches[1].Spans != 2 || ev.batches[1].Seq != 2 {
		t.Fatalf("batches: %+v", ev.batches)
	}
}

func TestWriterCloseFlushesPending(t *testing.T) {
	s := openTest(t)
	ev := newEvents()
	w := NewWriter(s, 86400, ev)
	w.MaxDelay = time.Hour
	w.Start()
	w.Submit(t.Context(), &Batch{Spans: []Span{span("t", "a", "", "x", 0, 1, 0)}})
	w.Close()
	if len(ev.batches) != 1 {
		t.Fatalf("close did not flush: %+v", ev.batches)
	}
	if err := w.Submit(t.Context(), &Batch{Spans: []Span{span("t", "b", "", "x", 0, 1, 0)}}); err != ErrClosed {
		t.Fatalf("submit after close: %v", err)
	}
}

func TestWriterSetRetentionPrunes(t *testing.T) {
	s := openTest(t)
	now := int64(100_000 * time.Second)
	s.Now = func() int64 { return now - int64(2*time.Hour) }
	commit(t, s, &Batch{Spans: []Span{span("old", "a", "", "x", 0, 1, 0)}})
	s.Now = func() int64 { return now }
	ev := newEvents()
	w := NewWriter(s, 86400, ev)
	w.Start()
	defer w.Close()
	w.SetRetention(3600)
	ev.wait(t)
	ev.mu.Lock()
	defer ev.mu.Unlock()
	if len(ev.pruned) != 1 || ev.pruned[0] != (PruneResult{Traces: 1, Spans: 1}) {
		t.Fatalf("pruned: %+v", ev.pruned)
	}
}

func TestCutoffNeverOverflows(t *testing.T) {
	now := time.Date(2026, 11, 2, 0, 0, 0, 0, time.UTC).UnixNano()
	if got := Cutoff(now, 3600); got != now-3600*int64(time.Second) {
		t.Fatalf("1 h: %d", got)
	}
	// 1e11 s times 1e9 overflows int64; without the guard the cutoff lands in
	// the future and every trace would be pruned.
	for _, r := range []int64{1e11, 9223372037, 1<<63 - 1} {
		if got := Cutoff(now, r); got > now {
			t.Fatalf("retention %d: cutoff %d is after now %d", r, got, now)
		}
	}
}

func TestOpenRefusesNewerSchema(t *testing.T) {
	path := filepath.Join(tmpDir(t), "magnife.sqlite")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec("PRAGMA user_version = 2"); err != nil {
		t.Fatal(err)
	}
	s.Close()
	if s, err := Open(path); err == nil || !strings.Contains(err.Error(), "newer") {
		if s != nil {
			s.Close()
		}
		t.Fatalf("Open of a version 2 database: %v, want a 'newer' error", err)
	}
}

func TestWriterCloseWithinDropsWhatIsLate(t *testing.T) {
	s := openTest(t)
	ev := newEvents()
	w := NewWriter(s, 86400, ev)
	w.MaxRecords = 1 // one commit per batch, so draining takes a while
	w.Start()
	const n = 250
	for i := range n {
		id := strconv.Itoa(i)
		w.Submit(t.Context(), &Batch{Spans: []Span{span("t"+id, "a", "", "x", 0, 1, 0)}})
	}
	began := time.Now()
	dropped := w.CloseWithin(time.Millisecond)
	if took := time.Since(began); took > 500*time.Millisecond {
		t.Fatalf("CloseWithin(1ms) took %v", took)
	}
	var stored int
	s.db.QueryRow("SELECT COUNT(*) FROM spans").Scan(&stored)
	if dropped == 0 || stored+dropped != n {
		t.Fatalf("stored %d + dropped %d, want %d with some dropped", stored, dropped, n)
	}
	t.Logf("stored %d, dropped %d", stored, dropped)
}
