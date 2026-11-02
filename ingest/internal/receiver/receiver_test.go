package receiver

import (
	"bytes"
	"compress/gzip"
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"go.opentelemetry.io/collector/pdata/plog/plogotlp"
	"go.opentelemetry.io/collector/pdata/pmetric"
	"go.opentelemetry.io/collector/pdata/pmetric/pmetricotlp"
	"go.opentelemetry.io/collector/pdata/ptrace/ptraceotlp"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"magnife/ingest/internal/sample"
	"magnife/ingest/internal/store"
)

type nopEvents struct{}

func (nopEvents) Batch(store.BatchResult)  {}
func (nopEvents) Pruned(store.PruneResult) {}
func (nopEvents) Error(error)              {}

// harness is a store, its writer and a receiver.
type harness struct {
	st *store.Store
	w  *store.Writer
	r  *Receiver
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "magnife-receiver-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	st, err := store.Open(filepath.Join(dir, "m.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	w := store.NewWriter(st, 86400, nopEvents{})
	w.Start()
	t.Cleanup(func() { w.Close(); st.Close() })
	return &harness{st: st, w: w, r: &Receiver{Sink: w}}
}

// seed builds the deterministic seed set at a fixed time.
func seed() *sample.Batch {
	b := sample.NewBatch()
	base := time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC)
	for i, sc := range sample.Scenarios {
		sc.Add(sample.SeedGen(sc.Name), b, base.Add(time.Duration(i)*time.Second), 1)
	}
	return b
}

// dump returns every stored span and log as text, without row ids and
// receive times.
func (h *harness) dump(t *testing.T) []string {
	t.Helper()
	h.w.Close() // commits everything queued
	var out []string
	for _, q := range []string{
		`SELECT trace_id, span_id, ifnull(parent_span_id, '-'), name, kind, start_ns, end_ns, duration_ns, status_code,
			status_message, service_name, scope_name, scope_version, attributes, events, links, ifnull(db_system, '-'),
			ifnull(db_statement, '-'), ifnull(http_method, '-'), ifnull(http_status_code, '-'), ifnull(http_route, '-'),
			ifnull(http_url, '-') FROM spans ORDER BY trace_id, span_id`,
		`SELECT time_ns, observed_ns, severity_number, severity_text, service_name, scope_name, body, attributes,
			ifnull(trace_id, '-'), ifnull(span_id, '-') FROM logs ORDER BY time_ns, body`,
		`SELECT trace_id, ifnull(root_span_id, '-'), root_service, route, duration_ns, span_count, error_count, status FROM traces ORDER BY trace_id`,
		`SELECT hash, service_name, attributes FROM resources ORDER BY hash`,
	} {
		rows, err := h.st.DB().Query(q)
		if err != nil {
			t.Fatal(err)
		}
		cols, _ := rows.Columns()
		for rows.Next() {
			vals := make([]any, len(cols))
			ptrs := make([]any, len(cols))
			for i := range vals {
				ptrs[i] = &vals[i]
			}
			rows.Scan(ptrs...)
			var sb strings.Builder
			for _, v := range vals {
				sb.WriteString(toString(v))
				sb.WriteByte('|')
			}
			out = append(out, sb.String())
		}
		rows.Close()
	}
	return out
}

func toString(v any) string {
	if b, ok := v.([]byte); ok {
		return string(b)
	}
	return fmt.Sprint(v)
}

func post(t *testing.T, url, contentType, encoding string, body []byte) *http.Response {
	t.Helper()
	if encoding == "gzip" {
		var buf bytes.Buffer
		zw := gzip.NewWriter(&buf)
		zw.Write(body)
		zw.Close()
		body = buf.Bytes()
	}
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	req.Header.Set("Content-Type", contentType)
	if encoding != "" {
		req.Header.Set("Content-Encoding", encoding)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func TestHTTPEncodingsStoreSameRows(t *testing.T) {
	b := seed()
	traceProto, _ := ptraceotlp.NewExportRequestFromTraces(b.Traces).MarshalProto()
	traceJSON, _ := ptraceotlp.NewExportRequestFromTraces(b.Traces).MarshalJSON()
	logProto, _ := plogotlp.NewExportRequestFromLogs(b.Logs).MarshalProto()
	logJSON, _ := plogotlp.NewExportRequestFromLogs(b.Logs).MarshalJSON()
	if !bytes.Contains(traceJSON, []byte(`"traceId":"`)) {
		t.Fatal("expected hex trace ids in OTLP JSON")
	}

	variants := []struct {
		name, contentType, encoding string
		traces, logs                []byte
	}{
		{"protobuf", "application/x-protobuf", "", traceProto, logProto},
		{"json", "application/json", "", traceJSON, logJSON},
		{"protobuf+gzip", "application/x-protobuf", "gzip", traceProto, logProto},
		{"json+gzip", "application/json; charset=utf-8", "gzip", traceJSON, logJSON},
	}
	var first []string
	for _, v := range variants {
		h := newHarness(t)
		srv := httptest.NewServer(h.r.HTTPHandler())
		for path, body := range map[string][]byte{"/v1/traces": v.traces, "/v1/logs": v.logs} {
			resp := post(t, srv.URL+path, v.contentType, v.encoding, body)
			resp.Body.Close()
			if resp.StatusCode != 200 {
				t.Fatalf("%s %s: %d", v.name, path, resp.StatusCode)
			}
		}
		srv.Close()
		got := h.dump(t)
		if len(got) < b.SpanCount()+b.LogCount() {
			t.Fatalf("%s: only %d rows", v.name, len(got))
		}
		if first == nil {
			first = got
			continue
		}
		if !reflect.DeepEqual(first, got) {
			for i := range min(len(first), len(got)) {
				if first[i] != got[i] {
					t.Fatalf("%s differs from protobuf at row %d:\n%s\n%s", v.name, i, first[i], got[i])
				}
			}
			t.Fatalf("%s: %d rows, protobuf %d", v.name, len(got), len(first))
		}
	}
}

func TestHTTPErrors(t *testing.T) {
	h := newHarness(t)
	srv := httptest.NewServer(h.r.HTTPHandler())
	defer srv.Close()
	good, _ := ptraceotlp.NewExportRequestFromTraces(seed().Traces).MarshalProto()

	cases := []struct {
		name, method, path, contentType, encoding string
		body                                      []byte
		want                                      int
	}{
		{"unsupported content type", "POST", "/v1/traces", "text/plain", "", good, 415},
		{"missing content type", "POST", "/v1/logs", "", "", good, 415},
		{"unsupported encoding", "POST", "/v1/traces", "application/x-protobuf", "br", good, 415},
		{"bad protobuf", "POST", "/v1/traces", "application/x-protobuf", "", []byte{0xff, 0xff, 0xff}, 400},
		{"bad json", "POST", "/v1/logs", "application/json", "", []byte(`{"resourceLogs": [`), 400},
		{"bad gzip", "POST", "/v1/traces", "application/x-protobuf", "gzip-raw", []byte("not gzip"), 400},
		{"get", "GET", "/v1/traces", "", "", nil, 405},
		{"put metrics", "PUT", "/v1/metrics", "application/json", "", nil, 405},
		{"unknown path", "POST", "/v1/profiles", "application/x-protobuf", "", good, 404},
	}
	for _, c := range cases {
		req, _ := http.NewRequest(c.method, srv.URL+c.path, bytes.NewReader(c.body))
		if c.contentType != "" {
			req.Header.Set("Content-Type", c.contentType)
		}
		switch c.encoding {
		case "gzip-raw":
			req.Header.Set("Content-Encoding", "gzip")
		case "":
		default:
			req.Header.Set("Content-Encoding", c.encoding)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != c.want {
			t.Errorf("%s: status %d, want %d", c.name, resp.StatusCode, c.want)
		}
		if c.want == 405 && resp.Header.Get("Allow") != "POST" {
			t.Errorf("%s: Allow = %q", c.name, resp.Header.Get("Allow"))
		}
	}
}

func TestHTTPResponseMatchesRequestEncoding(t *testing.T) {
	h := newHarness(t)
	srv := httptest.NewServer(h.r.HTTPHandler())
	defer srv.Close()

	md := pmetric.NewMetrics()
	md.ResourceMetrics().AppendEmpty().ScopeMetrics().AppendEmpty().Metrics().AppendEmpty().SetName("http.server.request.duration")
	metricsJSON, _ := pmetricotlp.NewExportRequestFromMetrics(md).MarshalJSON()
	tracesJSON, _ := ptraceotlp.NewExportRequestFromTraces(seed().Traces).MarshalJSON()
	tracesProto, _ := ptraceotlp.NewExportRequestFromTraces(seed().Traces).MarshalProto()

	for _, c := range []struct {
		path, contentType string
		body              []byte
	}{
		{"/v1/traces", "application/json", tracesJSON},
		{"/v1/traces", "application/x-protobuf", tracesProto},
		{"/v1/metrics", "application/json", metricsJSON},
	} {
		resp := post(t, srv.URL+c.path, c.contentType, "", c.body)
		var buf bytes.Buffer
		buf.ReadFrom(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != 200 || resp.Header.Get("Content-Type") != c.contentType {
			t.Fatalf("%s %s: %d %q", c.path, c.contentType, resp.StatusCode, resp.Header.Get("Content-Type"))
		}
		out := ptraceotlp.NewExportResponse()
		var err error
		if c.contentType == "application/json" {
			err = out.UnmarshalJSON(buf.Bytes())
		} else {
			err = out.UnmarshalProto(buf.Bytes())
		}
		if err != nil {
			t.Fatalf("%s: response does not decode: %v (%q)", c.path, err, buf.String())
		}
	}
	// Metrics are dropped.
	h.w.Close()
	var spans int
	h.st.DB().QueryRow("SELECT COUNT(*) FROM spans").Scan(&spans)
	// Both trace posts carry the same ids, so the second replaces the first.
	if spans != seed().SpanCount() {
		t.Fatalf("spans = %d", spans)
	}
}

func TestGRPCExportTracesAndLogs(t *testing.T) {
	h := newHarness(t)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := h.r.NewGRPCServer()
	go srv.Serve(ln)
	defer srv.Stop()

	conn, err := grpc.NewClient(ln.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	b := seed()
	gz := grpc.UseCompressor("gzip")
	if _, err := ptraceotlp.NewGRPCClient(conn).Export(ctx, ptraceotlp.NewExportRequestFromTraces(b.Traces), gz); err != nil {
		t.Fatal(err)
	}
	if _, err := plogotlp.NewGRPCClient(conn).Export(ctx, plogotlp.NewExportRequestFromLogs(b.Logs)); err != nil {
		t.Fatal(err)
	}
	md := pmetric.NewMetrics()
	md.ResourceMetrics().AppendEmpty()
	if _, err := pmetricotlp.NewGRPCClient(conn).Export(ctx, pmetricotlp.NewExportRequestFromMetrics(md), gz); err != nil {
		t.Fatal(err)
	}

	h.w.Close()
	var spans, logs, traces, errorTraces int
	db := h.st.DB()
	db.QueryRow("SELECT COUNT(*) FROM spans").Scan(&spans)
	db.QueryRow("SELECT COUNT(*) FROM logs").Scan(&logs)
	db.QueryRow("SELECT COUNT(*) FROM traces").Scan(&traces)
	db.QueryRow("SELECT COUNT(*) FROM traces WHERE status = 2").Scan(&errorTraces)
	if spans != b.SpanCount() || logs != b.LogCount() || traces != 5 || errorTraces != 2 {
		t.Fatalf("spans=%d/%d logs=%d/%d traces=%d errorTraces=%d", spans, b.SpanCount(), logs, b.LogCount(), traces, errorTraces)
	}

	// After the writer closes, exports fail with Unavailable instead of hanging.
	_, err = ptraceotlp.NewGRPCClient(conn).Export(ctx, ptraceotlp.NewExportRequestFromTraces(b.Traces))
	if err == nil || !strings.Contains(err.Error(), "Unavailable") {
		t.Fatalf("export after close: %v", err)
	}
}
