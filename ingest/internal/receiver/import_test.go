package receiver

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"go.opentelemetry.io/collector/pdata/plog/plogotlp"
	"go.opentelemetry.io/collector/pdata/pmetric"
	"go.opentelemetry.io/collector/pdata/pmetric/pmetricotlp"
	"go.opentelemetry.io/collector/pdata/ptrace/ptraceotlp"
)

// seedTraces is how many traces the seed set has (one per scenario).
const seedTraces = 5

// writeFile writes body to a file whose name has a space, as files people
// save often do.
func writeFile(t *testing.T, body []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "checkout trace.otlp.jsonl")
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// seedLines is the seed set as two JSON Lines: traces, then logs.
func seedLines(t *testing.T) []byte {
	t.Helper()
	b := seed()
	tr, err := ptraceotlp.NewExportRequestFromTraces(b.Traces).MarshalJSON()
	if err != nil {
		t.Fatal(err)
	}
	lg, err := plogotlp.NewExportRequestFromLogs(b.Logs).MarshalJSON()
	if err != nil {
		t.Fatal(err)
	}
	return bytes.Join([][]byte{tr, lg, nil}, []byte("\n"))
}

func TestImportFileStoresSameRowsAsExport(t *testing.T) {
	b := seed()
	live := newHarness(t)
	if _, _, err := live.r.Traces(context.Background(), b.Traces); err != nil {
		t.Fatal(err)
	}
	if err := live.r.Logs(context.Background(), b.Logs); err != nil {
		t.Fatal(err)
	}

	imported := newHarness(t)
	res, err := imported.r.ImportFile(context.Background(), writeFile(t, seedLines(t)))
	if err != nil {
		t.Fatal(err)
	}
	if res.Spans != b.SpanCount() || res.Logs != b.LogCount() || len(res.Traces) != seedTraces || res.Rejected != 0 {
		t.Fatalf("result %+v, want %d spans, %d logs, %d traces", res, b.SpanCount(), b.LogCount(), seedTraces)
	}

	// Committed before ImportFile returned: the app opens the traces at once.
	var n int
	if err := imported.st.DB().QueryRow(`SELECT count(*) FROM spans`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != b.SpanCount() {
		t.Fatalf("%d spans readable when ImportFile returned, want %d", n, b.SpanCount())
	}

	if got, want := imported.dump(t), live.dump(t); !reflect.DeepEqual(got, want) {
		t.Fatalf("imported rows differ from exported ones:\n got %d rows\nwant %d rows", len(got), len(want))
	}
}

func TestImportFileReadsOneDocument(t *testing.T) {
	tr, _ := ptraceotlp.NewExportRequestFromTraces(seed().Traces).MarshalJSON()
	var pretty bytes.Buffer
	if err := json.Indent(&pretty, tr, "", "  "); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t)
	res, err := h.r.ImportFile(context.Background(), writeFile(t, pretty.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	if res.Spans != seed().SpanCount() || res.Logs != 0 {
		t.Fatalf("result %+v", res)
	}
}

func TestImportFileKeepsTraceOrder(t *testing.T) {
	h := newHarness(t)
	res, err := h.r.ImportFile(context.Background(), writeFile(t, seedLines(t)))
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, id := range res.Traces {
		if len(id) != 32 || seen[id] {
			t.Fatalf("trace ids %v: want distinct 32-character ids", res.Traces)
		}
		seen[id] = true
	}
}

func TestImportFileErrors(t *testing.T) {
	metrics := pmetric.NewMetrics()
	metrics.ResourceMetrics().AppendEmpty().ScopeMetrics().AppendEmpty().Metrics().AppendEmpty().SetName("m")
	metricsLine, _ := pmetricotlp.NewExportRequestFromMetrics(metrics).MarshalJSON()
	tr, _ := ptraceotlp.NewExportRequestFromTraces(seed().Traces).MarshalJSON()

	cases := []struct {
		name string
		path func(t *testing.T) string
		want string
	}{
		{"missing", func(t *testing.T) string { return filepath.Join(t.TempDir(), "gone.jsonl") }, "The file does not exist."},
		{"folder", func(t *testing.T) string { return t.TempDir() }, "This is not a regular file."},
		{"empty", func(t *testing.T) string { return writeFile(t, []byte(" \n\n")) }, "The file is empty."},
		{"not json", func(t *testing.T) string {
			return writeFile(t, append(append(tr, '\n'), []byte("not json\n")...))
		}, "Line 2 is not valid JSON."},
		{"not otlp", func(t *testing.T) string { return writeFile(t, []byte(`{"spans":[]}`)) }, "The file has no resourceSpans or resourceLogs"},
		{"bad spans", func(t *testing.T) string {
			return writeFile(t, []byte(`{"resourceSpans":[{"scopeSpans":[{"spans":[{"traceId":"zz"}]}]}]}`))
		}, "The file has spans that cannot be read"},
		{"metrics only", func(t *testing.T) string { return writeFile(t, metricsLine) }, "The file has no spans or logs."},
		{"too deep", func(t *testing.T) string {
			return writeFile(t, []byte(`{"resourceSpans":`+strings.Repeat("[", maxJSONDepth+1)+strings.Repeat("]", maxJSONDepth+1)+`}`))
		}, "nests too deeply"},
		{"too large", func(t *testing.T) string {
			path := writeFile(t, nil)
			if err := os.Truncate(path, MaxImportBytes+1); err != nil {
				t.Fatal(err)
			}
			return path
		}, "The file is larger than 64 MB."},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := newHarness(t)
			_, err := h.r.ImportFile(context.Background(), c.path(t))
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("error %v, want one containing %q", err, c.want)
			}
		})
	}
}

// TestImportMagnifeExport imports the file the app's File > Export Trace…
// writes for a fixed trace (app/Tests/MagnifeKitTests/TraceExportTests.swift
// checks it byte for byte), and checks the rows hold what the app exported:
// both sides of the OTLP JSON round trip in one fixture.
func TestImportMagnifeExport(t *testing.T) {
	h := newHarness(t)
	res, err := h.r.ImportFile(context.Background(), filepath.Join("testdata", "magnife-export.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	const trace = "4bf92f3577b34da6a3ce929d0e0e4736"
	if res.Spans != 2 || res.Logs != 2 || !reflect.DeepEqual(res.Traces, []string{trace}) {
		t.Fatalf("result %+v", res)
	}

	sameJSON := func(t *testing.T, what, got, want string) {
		t.Helper()
		var g, w any
		if err := json.Unmarshal([]byte(got), &g); err != nil {
			t.Fatalf("%s: %v in %s", what, err, got)
		}
		json.Unmarshal([]byte(want), &w)
		if !reflect.DeepEqual(g, w) {
			t.Fatalf("%s:\n got %s\nwant %s", what, got, want)
		}
	}

	type span struct {
		parent, name, scope, version, message, service, attributes, events, links, resource string
		kind, status                                                                        int
		start, end                                                                          int64
	}
	read := func(id string) span {
		var s span
		err := h.st.DB().QueryRow(`SELECT ifnull(s.parent_span_id, ''), s.name, s.kind, s.start_ns, s.end_ns, s.status_code,
			s.status_message, s.service_name, s.scope_name, s.scope_version, s.attributes, s.events, s.links, r.attributes
			FROM spans s JOIN resources r ON r.id = s.resource_id WHERE s.trace_id = ? AND s.span_id = ?`, trace, id).
			Scan(&s.parent, &s.name, &s.kind, &s.start, &s.end, &s.status, &s.message, &s.service, &s.scope, &s.version,
				&s.attributes, &s.events, &s.links, &s.resource)
		if err != nil {
			t.Fatal(err)
		}
		return s
	}

	root := read("00f067aa0ba902b7")
	if root.parent != "" || root.name != "POST /checkout" || root.kind != 2 || root.status != 2 ||
		root.start != 1793000000000000000 || root.end != 1793000000120000000 ||
		root.scope != "Microsoft.AspNetCore" || root.version != "8.0.0" || root.service != "checkout-api" {
		t.Fatalf("root span %+v", root)
	}
	sameJSON(t, "root attributes", root.attributes,
		`{"http.request.method":"POST","http.response.status_code":500,"http.route":"/checkout","retry":false,"sampled.ratio":0.25,"tags":["a",1,true],"user":{"id":42,"plan":"pro"},"empty":null}`)
	sameJSON(t, "root links", root.links,
		`[{"trace_id":"0af7651916cd43dd8448eb211c80319c","span_id":"b7ad6b7169203331","attributes":{"link.kind":"retry"}}]`)
	sameJSON(t, "root resource", root.resource,
		`{"host.name":"mac.local","service.name":"checkout-api","telemetry.sdk.language":"dotnet"}`)

	child := read("53995c3f42cd8ad8")
	if child.parent != "00f067aa0ba902b7" || child.kind != 3 || child.message != "card declined" || child.service != "payments" {
		t.Fatalf("child span %+v", child)
	}
	sameJSON(t, "child events", child.events,
		`[{"time_ns":1793000000090000000,"name":"exception","attributes":{"exception.message":"card declined","exception.stacktrace":"at Pay()\n  at Main()","exception.type":"CardError"}}]`)

	// The trace row is recomputed from the imported spans, findings and all.
	var route string
	var status, spans int
	if err := h.st.DB().QueryRow(`SELECT route, status, span_count FROM traces WHERE trace_id = ?`, trace).Scan(&route, &status, &spans); err != nil {
		t.Fatal(err)
	}
	if route != "POST /checkout" || status != 2 || spans != 2 {
		t.Fatalf("trace row: %q, status %d, %d spans", route, status, spans)
	}

	var logs []string
	rows, err := h.st.DB().Query(`SELECT time_ns, observed_ns, severity_number, severity_text, body, attributes,
		ifnull(span_id, '-'), event_name FROM logs WHERE trace_id = ? ORDER BY time_ns`, trace)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var tm, obs int64
		var sev int
		var text, body, attrs, spanID, event string
		rows.Scan(&tm, &obs, &sev, &text, &body, &attrs, &spanID, &event)
		logs = append(logs, fmt.Sprintf("%d %d %d %s %q %s %s %s", tm, obs, sev, text, body, attrs, spanID, event))
	}
	want := []string{
		`1793000000095000000 1793000000095000100 17 Error "charge failed: card declined" {"order.id":"A-17"} 53995c3f42cd8ad8 `,
		`1793000000119000000 0 9 Information "{\"msg\":\"checkout done\"}" {} - checkout.done`,
	}
	if !reflect.DeepEqual(logs, want) {
		t.Fatalf("logs:\n got %q\nwant %q", logs, want)
	}
}
