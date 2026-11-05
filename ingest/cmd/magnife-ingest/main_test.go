package main

import (
	"bufio"
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"go.opentelemetry.io/collector/pdata/plog/plogotlp"
	"go.opentelemetry.io/collector/pdata/ptrace/ptraceotlp"
	_ "modernc.org/sqlite"

	"magnife/ingest/internal/sample"
	"magnife/ingest/internal/store"
)

// TestMain runs the real helper when the test binary is re-executed with
// MAGNIFE_INGEST_MAIN=1, so these tests drive a separate process exactly as
// the app does.
func TestMain(m *testing.M) {
	switch {
	case os.Getenv("MAGNIFE_INGEST_MAIN") == "1":
		os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
	case os.Getenv("MAGNIFE_FAKE_APP") == "1":
		fakeApp(os.Args[1:])
	}
	os.Exit(m.Run())
}

// fakeApp plays the Magnife app: it starts the helper with a stdin pipe it
// never closes, shares its stdout, prints the helper's pid on stderr and
// waits to be killed.
func fakeApp(args []string) {
	cmd := exec.Command(os.Args[0], args...)
	cmd.Env = append(os.Environ(), "MAGNIFE_INGEST_MAIN=1", "MAGNIFE_FAKE_APP=0")
	cmd.Stdout = os.Stdout
	cmd.Stderr = io.Discard
	stdin, err := cmd.StdinPipe()
	if err != nil {
		os.Exit(3)
	}
	if err := cmd.Start(); err != nil {
		os.Exit(3)
	}
	fmt.Fprintf(os.Stderr, "%d\n", cmd.Process.Pid)
	defer stdin.Close()
	select {}
}

type proc struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	lines  chan string
	stderr *syncWriter
	dbPath string
	exited chan struct{}
}

func testDB(t *testing.T) string {
	dir, err := os.MkdirTemp("/tmp", "magnife-ingest-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return filepath.Join(dir, "db", "magnife.sqlite")
}

// start runs the helper with free ports unless args override them.
func start(t *testing.T, db string, args ...string) *proc {
	t.Helper()
	all := append([]string{"--db", db, "--grpc", "127.0.0.1:0", "--http", "127.0.0.1:0"}, args...)
	cmd := exec.Command(os.Args[0], all...)
	// The race detector sleeps 1 s at exit by default; that is not the helper's time.
	cmd.Env = append(os.Environ(), "MAGNIFE_INGEST_MAIN=1", "GORACE=atexit_sleep_ms=0")
	p := &proc{cmd: cmd, lines: make(chan string, 1000), stderr: &syncWriter{}, dbPath: db, exited: make(chan struct{})}
	cmd.Stderr = p.stderr
	p.stdin, _ = cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	go func() {
		sc := bufio.NewScanner(stdout)
		sc.Buffer(nil, 16<<20)
		for sc.Scan() {
			p.lines <- sc.Text()
		}
		close(p.lines)
	}()
	go func() { cmd.Wait(); close(p.exited) }()
	t.Cleanup(func() {
		p.stdin.Close()
		select {
		case <-p.exited:
		case <-time.After(5 * time.Second):
			cmd.Process.Kill()
		}
		if t.Failed() {
			t.Logf("helper stderr:\n%s", p.stderr.String())
		}
	})
	return p
}

// syncWriter collects the helper's stderr while tests read it.
type syncWriter struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (s *syncWriter) Write(b []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.Write(b)
}

func (s *syncWriter) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.String()
}

// next returns the next stdout line of the given type, checking that every
// line on the way is a JSON object with a type.
func (p *proc) next(t *testing.T, typ string, timeout time.Duration) (string, map[string]any) {
	t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case line, ok := <-p.lines:
			if !ok {
				t.Fatalf("stdout closed while waiting for %q", typ)
			}
			var m map[string]any
			if err := json.Unmarshal([]byte(line), &m); err != nil || m["type"] == nil {
				t.Fatalf("stdout line is not a protocol line: %q", line)
			}
			if m["type"] == typ {
				return line, m
			}
		case <-deadline:
			t.Fatalf("no %q line within %v", typ, timeout)
		}
	}
}

type portInfo struct {
	Addr  string `json:"addr"`
	State string `json:"state"`
	Owner string `json:"owner"`
	PID   int    `json:"pid"`
}

func (p *proc) ports(t *testing.T) (grpcPort, httpPort portInfo) {
	t.Helper()
	line, _ := p.next(t, "ports", 10*time.Second)
	var v struct{ GRPC, HTTP portInfo }
	json.Unmarshal([]byte(line), &v)
	return v.GRPC, v.HTTP
}

func postSeed(t *testing.T, httpAddr string) *sample.Batch {
	t.Helper()
	b := sample.NewBatch()
	now := time.Now()
	for i, sc := range sample.Scenarios {
		sc.Add(sample.SeedGen(sc.Name), b, now.Add(-time.Duration(len(sample.Scenarios)-i)*time.Second), 1)
	}
	tr, _ := ptraceotlp.NewExportRequestFromTraces(b.Traces).MarshalProto()
	lg, _ := plogotlp.NewExportRequestFromLogs(b.Logs).MarshalProto()
	for path, body := range map[string][]byte{"/v1/traces": tr, "/v1/logs": lg} {
		resp, err := http.Post("http://"+httpAddr+path, "application/x-protobuf", bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != 200 {
			t.Fatalf("%s: %d", path, resp.StatusCode)
		}
	}
	return b
}

var batchLine = regexp.MustCompile(`^\{"type":"batch","seq":\d+,"spans":\d+,"logs":\d+,"traces":\[("[0-9a-f]{32}"(,"[0-9a-f]{32}")*)?\],"error_traces":\[("[0-9a-f]{32}"(,"[0-9a-f]{32}")*)?\]\}$`)

func TestPortsThenBatchLines(t *testing.T) {
	p := start(t, testDB(t))
	g, h := p.ports(t)
	if g.State != "listening" || h.State != "listening" || !strings.HasPrefix(h.Addr, "127.0.0.1:") || strings.HasSuffix(h.Addr, ":0") {
		t.Fatalf("ports: %+v %+v", g, h)
	}
	b := postSeed(t, h.Addr)

	var spans, logs int
	var lastSeq float64
	traces, errorTraces := map[string]bool{}, map[string]bool{}
	for spans < b.SpanCount() || logs < b.LogCount() {
		line, m := p.next(t, "batch", 5*time.Second)
		if !batchLine.MatchString(line) {
			t.Fatalf("batch line format: %s", line)
		}
		if m["seq"].(float64) != lastSeq+1 {
			t.Fatalf("seq %v after %v", m["seq"], lastSeq)
		}
		lastSeq = m["seq"].(float64)
		spans += int(m["spans"].(float64))
		logs += int(m["logs"].(float64))
		for _, id := range m["traces"].([]any) {
			traces[id.(string)] = true
		}
		for _, id := range m["error_traces"].([]any) {
			errorTraces[id.(string)] = true
		}
	}
	if spans != b.SpanCount() || logs != b.LogCount() || len(traces) != 5 || len(errorTraces) != 2 {
		t.Fatalf("spans=%d logs=%d traces=%d error_traces=%d", spans, logs, len(traces), len(errorTraces))
	}
	if strings.Contains(p.stderr.String(), `"type"`) {
		t.Fatal("protocol lines leaked to stderr")
	}
}

func TestStdinEOFFlushesAndExitsWithinOneSecond(t *testing.T) {
	db := testDB(t)
	// A long retention keeps the startup prune from deleting anything.
	p := start(t, db, "-v")
	_, h := p.ports(t)
	b := postSeed(t, h.Addr)

	began := time.Now()
	p.stdin.Close() // right after the export, while the batch may still be pending
	select {
	case <-p.exited:
	case <-time.After(3 * time.Second):
		t.Fatal("helper still running 3 s after stdin closed")
	}
	took := time.Since(began)
	t.Logf("exit %v after stdin EOF", took)
	if took > 100*time.Millisecond {
		t.Log(p.stderr.String())
	}
	if took > time.Second {
		t.Fatalf("exit took %v, want under 1 s", took)
	}
	if code := p.cmd.ProcessState.ExitCode(); code != 0 {
		t.Fatalf("exit code %d", code)
	}
	conn, err := sql.Open("sqlite", "file:"+db+"?mode=ro")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	var spans, logs int
	conn.QueryRow("SELECT COUNT(*) FROM spans").Scan(&spans)
	conn.QueryRow("SELECT COUNT(*) FROM logs").Scan(&logs)
	if spans != b.SpanCount() || logs != b.LogCount() {
		t.Fatalf("after exit: spans=%d logs=%d, want %d %d", spans, logs, b.SpanCount(), b.LogCount())
	}
}

func TestBusyPortThenRetry(t *testing.T) {
	// This test process plays "another collector" on *:P, which a plain
	// SO_REUSEADDR bind of 127.0.0.1:P would not notice.
	holder, err := net.Listen("tcp4", "0.0.0.0:0")
	if err != nil {
		t.Fatal(err)
	}
	port := holder.Addr().(*net.TCPAddr).Port
	addr := fmt.Sprintf("127.0.0.1:%d", port)

	p := start(t, testDB(t), "--http", addr)
	g, h := p.ports(t)
	if g.State != "listening" || h.State != "busy" || h.Addr != addr || h.PID != os.Getpid() || h.Owner == "" {
		t.Fatalf("ports: grpc %+v http %+v (want http busy, owner pid %d)", g, h, os.Getpid())
	}
	t.Logf("busy port reported: %+v", h)

	holder.Close()
	fmt.Fprintln(p.stdin, "retry")
	g, h = p.ports(t)
	if h.State != "listening" || h.Addr != addr || g.State != "listening" {
		t.Fatalf("after retry: grpc %+v http %+v", g, h)
	}
	postSeed(t, h.Addr)
	p.next(t, "batch", 5*time.Second)
}

func TestRetentionCommandPrunes(t *testing.T) {
	p := start(t, testDB(t))
	_, h := p.ports(t)
	b := postSeed(t, h.Addr)
	for n := 0; n < b.SpanCount(); {
		_, m := p.next(t, "batch", 5*time.Second)
		n += int(m["spans"].(float64))
	}
	time.Sleep(1100 * time.Millisecond)
	fmt.Fprintln(p.stdin, "retention 1")
	line, _ := p.next(t, "pruned", 5*time.Second)
	want := fmt.Sprintf(`{"type":"pruned","traces":5,"spans":%d,"logs":%d}`, b.SpanCount(), b.LogCount())
	if line != want {
		t.Fatalf("got  %s\nwant %s", line, want)
	}

	// Nothing left: "prune" prints nothing, and the helper keeps answering.
	fmt.Fprintln(p.stdin, "prune")
	fmt.Fprintln(p.stdin, "retry")
	if line, _ := p.next(t, "ports", 5*time.Second); strings.Contains(line, "pruned") {
		t.Fatal(line)
	}
	select {
	case line := <-p.lines:
		t.Fatalf("unexpected line: %s", line)
	case <-time.After(200 * time.Millisecond):
	}
}

func TestDatabaseErrorLine(t *testing.T) {
	p := start(t, "/dev/null/magnife/magnife.sqlite")
	line, m := p.next(t, "error", 5*time.Second)
	if !strings.Contains(m["message"].(string), "database") {
		t.Fatalf("error line: %s", line)
	}
	<-p.exited
	if code := p.cmd.ProcessState.ExitCode(); code != 1 {
		t.Fatalf("exit code %d", code)
	}
}

func TestNonLoopbackAddressRefused(t *testing.T) {
	p := start(t, testDB(t), "--http", "0.0.0.0:4318")
	p.next(t, "error", 5*time.Second)
	<-p.exited
	if code := p.cmd.ProcessState.ExitCode(); code != 2 {
		t.Fatalf("exit code %d", code)
	}
}

func TestNoStdinIgnoresEOFAndStopsOnSIGTERM(t *testing.T) {
	p := start(t, testDB(t), "--no-stdin")
	p.ports(t)
	p.stdin.Close()
	select {
	case <-p.exited:
		t.Fatal("--no-stdin helper exited on stdin EOF")
	case <-time.After(300 * time.Millisecond):
	}
	p.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-p.exited:
	case <-time.After(2 * time.Second):
		t.Fatal("no exit after SIGTERM")
	}
	if code := p.cmd.ProcessState.ExitCode(); code != 0 {
		t.Fatalf("exit code %d", code)
	}
}

func TestStartupPrunesAfterPortsLine(t *testing.T) {
	db := testDB(t)
	st, err := store.Open(db)
	if err != nil {
		t.Fatal(err)
	}
	st.Now = func() int64 { return time.Now().Add(-2 * time.Hour).UnixNano() }
	old := store.Span{Resource: &store.Resource{Hash: "h", ServiceName: "orders", Attributes: "{}"},
		TraceID: "0123456789abcdef0123456789abcdef", SpanID: "0123456789abcdef", Name: "old",
		Attributes: "{}", Events: "[]", Links: "[]"}
	if _, err := st.Commit([]*store.Batch{{Spans: []store.Span{old}}}); err != nil {
		t.Fatal(err)
	}
	st.Close()

	p := start(t, db, "--retention", "3600")
	first := <-p.lines
	if !strings.HasPrefix(first, `{"type":"ports"`) {
		t.Fatalf("first line is not ports: %s", first)
	}
	line, _ := p.next(t, "pruned", 5*time.Second)
	if line != `{"type":"pruned","traces":1,"spans":1,"logs":0}` {
		t.Fatal(line)
	}
	// Seqs continue from the database.
	_, h := portsFrom(t, first)
	postSeed(t, h.Addr)
	if _, m := p.next(t, "batch", 5*time.Second); m["seq"].(float64) != 2 {
		t.Fatalf("seq %v, want 2", m["seq"])
	}
}

func portsFrom(t *testing.T, line string) (portInfo, portInfo) {
	var v struct{ GRPC, HTTP portInfo }
	if err := json.Unmarshal([]byte(line), &v); err != nil {
		t.Fatal(err)
	}
	return v.GRPC, v.HTTP
}

func TestHelperExitsWhenAppIsKilled(t *testing.T) {
	cmd := exec.Command(os.Args[0], "--db", testDB(t), "--grpc", "127.0.0.1:0", "--http", "127.0.0.1:0")
	cmd.Env = append(os.Environ(), "MAGNIFE_FAKE_APP=1", "GORACE=atexit_sleep_ms=0")
	stdout, _ := cmd.StdoutPipe()
	stderr, _ := cmd.StderrPipe()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Wait()
	var helperPID int
	if _, err := fmt.Fscan(stderr, &helperPID); err != nil {
		cmd.Process.Kill()
		t.Fatal(err)
	}
	t.Cleanup(func() { syscall.Kill(helperPID, syscall.SIGKILL) })
	out := bufio.NewReader(stdout)
	if line, err := out.ReadString('\n'); err != nil || !strings.HasPrefix(line, `{"type":"ports"`) {
		cmd.Process.Kill()
		t.Fatalf("first line %q, %v", line, err)
	}

	// The helper's stdout write end is shared only by the two processes, so
	// EOF here means the helper is gone too.
	began := time.Now()
	cmd.Process.Kill()
	gone := make(chan struct{})
	go func() { io.Copy(io.Discard, out); close(gone) }()
	select {
	case <-gone:
	case <-time.After(3 * time.Second):
		t.Fatalf("helper %d still running 3 s after kill -9 of its parent", helperPID)
	}
	took := time.Since(began)
	t.Logf("helper exited %v after kill -9 of the app", took)
	if took > time.Second {
		t.Fatalf("helper exit took %v, want under 1 s", took)
	}
}

func TestBadCommandsAreIgnored(t *testing.T) {
	p := start(t, testDB(t))
	p.ports(t)
	for _, cmd := range []string{"bogus", strings.Repeat("retention 1 ", 20_000), "retention abc", "retention -5", "retention 0", "prune now", "", "import", "import relative/path.jsonl"} {
		fmt.Fprintln(p.stdin, cmd)
	}
	// Still reading commands, and nothing but protocol lines on stdout.
	fmt.Fprintln(p.stdin, "retry")
	p.ports(t)
	select {
	case line := <-p.lines:
		t.Fatalf("unexpected line: %s", line)
	case <-p.exited:
		t.Fatal("helper exited")
	case <-time.After(200 * time.Millisecond):
	}
}

// TestImportCommand drives File > Import Traces… as the app does: the
// helper stores the file, sends its batch lines, then one "imported" line
// once the traces can be read; a file it cannot read is "import_failed".
func TestImportCommand(t *testing.T) {
	db := testDB(t)
	p := start(t, db)
	p.ports(t)

	b := sample.NewBatch()
	now := time.Now()
	for i, sc := range sample.Scenarios {
		sc.Add(sample.SeedGen(sc.Name), b, now.Add(-time.Duration(len(sample.Scenarios)-i)*time.Second), 1)
	}
	tr, _ := ptraceotlp.NewExportRequestFromTraces(b.Traces).MarshalJSON()
	lg, _ := plogotlp.NewExportRequestFromLogs(b.Logs).MarshalJSON()
	path := filepath.Join(t.TempDir(), "shared trace.otlp.jsonl")
	if err := os.WriteFile(path, append(append(append(tr, '\n'), lg...), '\n'), 0o600); err != nil {
		t.Fatal(err)
	}

	fmt.Fprintf(p.stdin, "import %s\n", path)
	_, m := p.next(t, "imported", 10*time.Second)
	if m["path"] != path || int(m["spans"].(float64)) != b.SpanCount() || int(m["logs"].(float64)) != b.LogCount() {
		t.Fatalf("imported line %v, want %s with %d spans and %d logs", m, path, b.SpanCount(), b.LogCount())
	}
	traces := m["traces"].([]any)
	if len(traces) != 5 { // as TestRetentionCommandPrunes: one scenario sends logs only
		t.Fatalf("imported %d traces, want 5", len(traces))
	}

	// The traces are readable when the line arrives.
	rdb, err := sql.Open("sqlite", "file:"+db+"?mode=ro")
	if err != nil {
		t.Fatal(err)
	}
	defer rdb.Close()
	var n int
	if err := rdb.QueryRow(`SELECT count(*) FROM traces WHERE trace_id = ?`, traces[0]).Scan(&n); err != nil || n != 1 {
		t.Fatalf("first imported trace: %d rows, %v", n, err)
	}

	missing := filepath.Join(t.TempDir(), "gone.jsonl")
	fmt.Fprintf(p.stdin, "import %s\n", missing)
	line, _ := p.next(t, "import_failed", 5*time.Second)
	want := fmt.Sprintf(`{"type":"import_failed","path":%q,"message":"The file does not exist."}`, missing)
	if line != want {
		t.Fatalf("got  %s\nwant %s", line, want)
	}
}

func TestGRPCBusyHTTPKeepsWorking(t *testing.T) {
	// A dual-stack wildcard listener, as a Docker port mapping or another
	// collector would hold it.
	holder, err := net.Listen("tcp", "[::]:0")
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Close()
	addr := fmt.Sprintf("127.0.0.1:%d", holder.Addr().(*net.TCPAddr).Port)

	p := start(t, testDB(t), "--grpc", addr)
	g, h := p.ports(t)
	if g.State != "busy" || g.Addr != addr || g.PID != os.Getpid() || g.Owner == "" || h.State != "listening" {
		t.Fatalf("ports: grpc %+v http %+v (want grpc busy, owner pid %d)", g, h, os.Getpid())
	}
	postSeed(t, h.Addr)
	p.next(t, "batch", 5*time.Second)
}

func TestBrokenStdoutPipeExits(t *testing.T) {
	db := testDB(t)
	cmd := exec.Command(os.Args[0], "--db", db, "--grpc", "127.0.0.1:0", "--http", "127.0.0.1:0")
	cmd.Env = append(os.Environ(), "MAGNIFE_INGEST_MAIN=1", "GORACE=atexit_sleep_ms=0")
	stdin, _ := cmd.StdinPipe()
	defer stdin.Close()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stdout = w
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	w.Close()
	exited := make(chan struct{})
	go func() { cmd.Wait(); close(exited) }()
	defer func() { cmd.Process.Kill(); <-exited }()

	line, err := bufio.NewReader(r).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	_, h := portsFrom(t, line)
	r.Close() // the app stopped reading: the next line hits EPIPE
	b := postSeed(t, h.Addr)
	select {
	case <-exited:
	case <-time.After(3 * time.Second):
		t.Fatal("helper still running after its stdout broke")
	}
	if code := cmd.ProcessState.ExitCode(); code != 0 {
		t.Fatalf("exit code %d (SIGPIPE would be -1)", code)
	}
	conn, err := sql.Open("sqlite", "file:"+db+"?mode=ro")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	var spans int
	conn.QueryRow("SELECT COUNT(*) FROM spans").Scan(&spans)
	if spans != b.SpanCount() {
		t.Fatalf("spans=%d, want %d committed before exit", spans, b.SpanCount())
	}
}
