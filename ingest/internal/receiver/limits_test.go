package receiver

import (
	"bytes"
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"go.opentelemetry.io/collector/pdata/ptrace"
	"go.opentelemetry.io/collector/pdata/ptrace/ptraceotlp"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protowire"

	"magnife/ingest/internal/convert"
	"magnife/ingest/internal/store"
)

// nestedTraceRequest is an ExportTraceServiceRequest with one span whose
// attribute "deep" is an array nested `levels` values deep. It is built
// inside out in reverse, so two million levels take linear time.
func nestedTraceRequest(levels int) []byte {
	// rev holds the message so far, reversed; wrap prepends a header.
	rev := []byte{'x', 1, 0x0a} // AnyValue{string_value: "x"}, reversed
	wrap := func(num protowire.Number) {
		var h []byte
		h = protowire.AppendTag(h, num, protowire.BytesType)
		h = protowire.AppendVarint(h, uint64(len(rev)))
		for i := len(h) - 1; i >= 0; i-- {
			rev = append(rev, h[i])
		}
	}
	prependField := func(num protowire.Number, v []byte) {
		var h []byte
		h = protowire.AppendTag(h, num, protowire.BytesType)
		h = protowire.AppendBytes(h, v)
		for i := len(h) - 1; i >= 0; i-- {
			rev = append(rev, h[i])
		}
	}
	for range levels - 1 {
		wrap(1) // ArrayValue.values
		wrap(5) // AnyValue.array_value
	}
	wrap(2)                         // KeyValue.value
	prependField(1, []byte("deep")) // KeyValue.key
	wrap(9)                         // Span.attributes
	prependField(5, []byte("GET /deep"))
	prependField(2, bytes.Repeat([]byte{2}, 8))  // span_id
	prependField(1, bytes.Repeat([]byte{1}, 16)) // trace_id
	wrap(2)                                      // ScopeSpans.spans
	wrap(2)                                      // ResourceSpans.scope_spans
	wrap(1)                                      // ExportTraceServiceRequest.resource_spans
	slices.Reverse(rev)
	return rev
}

// nestedJSON is the same request in OTLP/JSON.
func nestedJSON(levels int) []byte {
	var b bytes.Buffer
	b.WriteString(`{"resourceSpans":[{"scopeSpans":[{"spans":[{"traceId":"01010101010101010101010101010101","spanId":"0202020202020202","name":"GET /deep","attributes":[{"key":"deep","value":`)
	for range levels - 1 {
		b.WriteString(`{"arrayValue":{"values":[`)
	}
	b.WriteString(`{"stringValue":"x"}`)
	for range levels - 1 {
		b.WriteString(`]}}`)
	}
	b.WriteString(`}]}]}]}]}`)
	return b.Bytes()
}

func TestNestingWithinTheLimitIsStoredAndBeyondIsRefused(t *testing.T) {
	h := newHarness(t)
	srv := httptest.NewServer(h.r.HTTPHandler())
	defer srv.Close()

	// The encoders agree with pdata: the request at the limit decodes.
	req := ptraceotlp.NewExportRequest()
	if err := req.UnmarshalProto(nestedTraceRequest(MaxValueDepth)); err != nil || req.Traces().SpanCount() != 1 {
		t.Fatalf("hand-built request does not decode: %v", err)
	}
	req = ptraceotlp.NewExportRequest()
	if err := req.UnmarshalJSON(nestedJSON(MaxValueDepth)); err != nil || req.Traces().SpanCount() != 1 {
		t.Fatalf("hand-built JSON does not decode: %v", err)
	}

	for _, c := range []struct {
		name, contentType string
		body              []byte
		want              int
	}{
		{"proto at the limit", "application/x-protobuf", nestedTraceRequest(MaxValueDepth), 200},
		{"proto one deeper", "application/x-protobuf", nestedTraceRequest(MaxValueDepth + 1), 400},
		{"json at the limit", "application/json", nestedJSON(MaxValueDepth), 200},
		{"json far deeper", "application/json", nestedJSON(maxJSONDepth), 400},
		// Before the check, this one crashed the helper with a Go stack overflow.
		{"proto two million levels", "application/x-protobuf", nestedTraceRequest(2_000_000), 400},
		{"json a million levels", "application/json", nestedJSON(1_000_000), 400},
	} {
		resp := post(t, srv.URL+"/v1/traces", c.contentType, "", c.body)
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != c.want {
			t.Errorf("%s (%d bytes): status %d, want %d (%q)", c.name, len(c.body), resp.StatusCode, c.want, body)
		}
		if c.want == 400 && !bytes.Contains(body, []byte("nested more than 64 levels")) {
			t.Errorf("%s: body %q does not say why", c.name, body)
		}
	}
	// What was stored stays within SQLite's JSON limits: the attribute
	// filters' JSON functions run on every row (TraceFilterSQL).
	h.w.Close()
	var deep string
	err := h.st.DB().QueryRow(`SELECT attributes ->> '$.deep' FROM spans WHERE json_type(attributes, '$.deep') = 'array'`).Scan(&deep)
	if err != nil || !strings.Contains(deep, convert.TooDeep) {
		t.Fatalf("stored value: %v %.200q", err, deep)
	}
}

func TestGRPCRefusesDeepNestingWithInvalidArgument(t *testing.T) {
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
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	client := ptraceotlp.NewGRPCClient(conn)
	for _, c := range []struct {
		levels int
		want   codes.Code
	}{{MaxValueDepth, codes.OK}, {MaxValueDepth + 1, codes.InvalidArgument}, {2_000_000, codes.InvalidArgument}} {
		req := ptraceotlp.NewExportRequest()
		// The client re-encodes what it decoded; pdata cannot decode two
		// million levels either, so the deep one goes out as bytes.
		var err error
		if c.levels <= 1000 {
			if err := req.UnmarshalProto(nestedTraceRequest(c.levels)); err != nil {
				t.Fatal(err)
			}
			_, err = client.Export(ctx, req)
		} else {
			err = conn.Invoke(ctx, "/opentelemetry.proto.collector.trace.v1.TraceService/Export",
				&rawMessage{nestedTraceRequest(c.levels)}, &rawMessage{}, grpc.ForceCodecV2(rawCodec{}))
		}
		if got := status.Code(err); got != c.want {
			t.Errorf("%d levels: %v, want %v", c.levels, err, c.want)
		}
	}
}

func TestHTTPAcceptsOnlyRequestsAddressedToThisMac(t *testing.T) {
	h := newHarness(t)
	srv := httptest.NewServer(h.r.HTTPHandler())
	defer srv.Close()
	good, _ := ptraceotlp.NewExportRequestFromTraces(seed().Traces).MarshalProto()
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(srv.URL, "http://"))
	for _, c := range []struct {
		host, origin string
		want         int
	}{
		{"localhost:" + port, "", 200},
		{"127.0.0.1:" + port, "", 200},
		{"[::1]:" + port, "", 200},
		{"LOCALHOST", "", 200},
		{"host.docker.internal:" + port, "", 200},
		{"localhost:" + port, "http://localhost:3000", 200},
		// DNS rebinding: a web page whose domain now resolves to 127.0.0.1.
		{"attacker.example:" + port, "", 403},
		{"attacker.example:" + port, "http://attacker.example", 403},
		{"localhost:" + port, "http://attacker.example", 403},
		{"localhost:" + port, "null", 403},
		{"127.0.0.1.attacker.example", "", 403},
	} {
		req, _ := http.NewRequest(http.MethodPost, srv.URL+"/v1/traces", bytes.NewReader(good))
		req.Host = c.host
		req.Header.Set("Content-Type", "application/x-protobuf")
		if c.origin != "" {
			req.Header.Set("Origin", c.origin)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != c.want {
			t.Errorf("Host %q Origin %q: status %d, want %d", c.host, c.origin, resp.StatusCode, c.want)
		}
	}
}

func TestHTTPRefusesLargeBodiesEarly(t *testing.T) {
	h := newHarness(t)
	srv := httptest.NewServer(h.r.HTTPHandler())
	defer srv.Close()
	// A declared length over the cap is refused before the body is read.
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/v1/traces", io.LimitReader(zeros{}, MaxBodyBytes+1))
	req.ContentLength = MaxBodyBytes + 1
	req.Header.Set("Content-Type", "application/x-protobuf")
	resp, err := http.DefaultClient.Do(req)
	if err == nil {
		resp.Body.Close()
		if resp.StatusCode != http.StatusRequestEntityTooLarge {
			t.Fatalf("declared length: status %d", resp.StatusCode)
		}
	}
	// A gzip body that inflates past the cap.
	resp = post(t, srv.URL+"/v1/traces", "application/x-protobuf", "gzip", make([]byte, MaxBodyBytes+1024))
	resp.Body.Close()
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("gzip bomb: status %d", resp.StatusCode)
	}
}

// blockingSink counts concurrent Submits and holds each until released.
type blockingSink struct {
	now, peak atomic.Int32
	release   chan struct{}
}

func (s *blockingSink) Submit(ctx context.Context, b *store.Batch) error {
	n := s.now.Add(1)
	for {
		p := s.peak.Load()
		if n <= p || s.peak.CompareAndSwap(p, n) {
			break
		}
	}
	<-s.release
	s.now.Add(-1)
	return nil
}

func TestInFlightRequestsAreBoundedAcrossHTTPAndGRPC(t *testing.T) {
	sink := &blockingSink{release: make(chan struct{})}
	r := &Receiver{Sink: sink}
	srv := httptest.NewServer(r.HTTPHandler())
	defer srv.Close()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	gs := r.NewGRPCServer()
	go gs.Serve(ln)
	defer gs.Stop()
	conn, err := grpc.NewClient(ln.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	td := ptrace.NewTraces()
	sp := td.ResourceSpans().AppendEmpty().ScopeSpans().AppendEmpty().Spans().AppendEmpty()
	sp.SetTraceID([16]byte{1})
	sp.SetSpanID([8]byte{2})
	body, _ := ptraceotlp.NewExportRequestFromTraces(td).MarshalProto()

	var wg sync.WaitGroup
	for i := range 3 * MaxInFlight {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if i%2 == 0 {
				resp, err := http.Post(srv.URL+"/v1/traces", "application/x-protobuf", bytes.NewReader(body))
				if err == nil {
					resp.Body.Close()
				}
				return
			}
			ptraceotlp.NewGRPCClient(conn).Export(context.Background(), ptraceotlp.NewExportRequestFromTraces(td))
		}()
	}
	deadline := time.Now().Add(5 * time.Second)
	for sink.now.Load() < MaxInFlight && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(200 * time.Millisecond) // room for any request past the gate
	if got := sink.peak.Load(); got != MaxInFlight {
		t.Errorf("peak in-flight requests = %d, want %d", got, MaxInFlight)
	}
	close(sink.release)
	wg.Wait()
}

type zeros struct{}

func (zeros) Read(p []byte) (int, error) {
	clear(p)
	return len(p), nil
}
