// Package helper is the magnife-ingest process: it opens the database,
// starts the OTLP receivers and speaks the stdout/stdin protocol from
// docs/schema.sql.
package helper

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"google.golang.org/grpc"

	"magnife/ingest/internal/ports"
	"magnife/ingest/internal/receiver"
	"magnife/ingest/internal/store"
)

// Config holds the command-line flags.
type Config struct {
	DBPath     string
	GRPCAddr   string
	HTTPAddr   string
	RetentionS int64
	NoStdin    bool // run without the app: ignore stdin, stop on SIGINT/SIGTERM
}

// The helper must exit within a second of stdin closing (S-008), so the app
// can relaunch it at once. stopTimeout bounds in-flight requests; queued
// batches are committed until exitBudget has passed since EOF (at least
// drainFloor), and dropped after that.
const (
	stopTimeout = 300 * time.Millisecond
	exitBudget  = 700 * time.Millisecond
	drainFloor  = 100 * time.Millisecond
)

// endpoint is one port the helper listens on.
type endpoint struct {
	addr  string
	serve func(net.Listener) error
	ln    net.Listener
	state portState
}

// bind checks for another listener on the port, then listens if it is free.
func (e *endpoint) bind(ctx context.Context, name string) {
	if e.ln != nil {
		return
	}
	if owner := ports.Check(ctx, e.addr); owner.Busy {
		e.state = portState{Addr: e.addr, State: "busy", Owner: owner.Name, PID: owner.PID}
		slog.Warn("port is busy", "receiver", name, "addr", e.addr, "owner", owner.Name, "pid", owner.PID)
		return
	}
	ln, err := net.Listen("tcp", e.addr)
	if err != nil {
		e.state = portState{Addr: e.addr, State: "busy"}
		slog.Warn("cannot listen", "receiver", name, "addr", e.addr, "err", err)
		return
	}
	e.ln = ln
	e.state = portState{Addr: ln.Addr().String(), State: "listening"}
	slog.Info("listening", "receiver", name, "addr", e.state.Addr)
	go func() {
		if err := e.serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) && !errors.Is(err, grpc.ErrServerStopped) {
			slog.Error("server stopped", "receiver", name, "err", err)
		}
	}()
}

// checkLoopback enforces the contract's "binds 127.0.0.1 only".
func checkLoopback(flag, addr string) error {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("--%s %q: %v", flag, addr, err)
	}
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("--%s %q: the receiver only binds a loopback address such as 127.0.0.1", flag, addr)
	}
	return nil
}

// Run runs the helper until stdin reaches EOF (or a signal with NoStdin) and
// returns the exit code.
func Run(cfg Config, stdin io.Reader, stdout io.Writer) int {
	out := newEmitter(stdout)
	for _, c := range [][2]string{{"grpc", cfg.GRPCAddr}, {"http", cfg.HTTPAddr}} {
		if err := checkLoopback(c[0], c[1]); err != nil {
			out.errorf(err.Error())
			slog.Error("invalid flag", "err", err)
			return 2
		}
	}
	if cfg.RetentionS <= 0 {
		out.errorf("--retention must be a positive number of seconds")
		return 2
	}

	// A broken stdout pipe must surface as an error, not kill the process.
	signal.Notify(make(chan os.Signal, 1), syscall.SIGPIPE)
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(sigs)

	st, err := store.Open(cfg.DBPath)
	if err != nil {
		msg := fmt.Sprintf("Cannot open the database at %s: %v", cfg.DBPath, err)
		out.errorf(msg)
		slog.Error("cannot open database", "path", cfg.DBPath, "err", err)
		return 1
	}
	if err := st.SetMeta("retention_s", strconv.FormatInt(cfg.RetentionS, 10)); err != nil {
		slog.Error("cannot write meta", "err", err)
	}
	w := store.NewWriter(st, cfg.RetentionS, out)
	w.Start()

	recv := &receiver.Receiver{Sink: w}
	grpcSrv := recv.NewGRPCServer()
	fresh := &freshConns{conns: map[net.Conn]bool{}}
	httpSrv := &http.Server{Handler: recv.HTTPHandler(), ReadHeaderTimeout: 10 * time.Second, ConnState: fresh.track}
	grpcEP := &endpoint{addr: cfg.GRPCAddr, serve: grpcSrv.Serve}
	httpEP := &endpoint{addr: cfg.HTTPAddr, serve: httpSrv.Serve}
	bindAll := func() {
		var wg sync.WaitGroup
		wg.Add(2)
		go func() { defer wg.Done(); grpcEP.bind(context.Background(), "grpc") }()
		go func() { defer wg.Done(); httpEP.bind(context.Background(), "http") }()
		wg.Wait()
		out.ports(grpcEP.state, httpEP.state)
	}
	bindAll()
	w.Prune() // data may have expired while the helper was not running

	lines := make(chan string)
	eof := make(chan struct{})
	if cfg.NoStdin {
		slog.Info("ignoring stdin; stop with SIGINT or SIGTERM")
	} else {
		go readCommands(stdin, lines, eof)
	}

loop:
	for {
		select {
		case line := <-lines:
			handleCommand(line, w, bindAll)
		case <-eof:
			slog.Info("stdin closed; exiting")
			break loop
		case s := <-sigs:
			slog.Info("signal; exiting", "signal", s.String())
			break loop
		case <-out.broken:
			slog.Info("stdout closed; exiting")
			break loop
		}
	}

	began := time.Now()
	stopServers(httpSrv, grpcSrv, fresh)
	slog.Debug("servers stopped", "after", time.Since(began))
	if dropped := w.CloseWithin(max(drainFloor, exitBudget-time.Since(began))); dropped > 0 {
		slog.Warn("exiting with records still queued; they were not stored", "dropped", dropped)
	}
	slog.Debug("queued batches committed", "after", time.Since(began))
	if err := st.Close(); err != nil {
		slog.Error("close database", "err", err)
	}
	slog.Debug("database closed", "after", time.Since(began))
	return 0
}

// maxCommandBytes caps one stdin line; longer lines are dropped, not fatal.
const maxCommandBytes = 4096

// readCommands sends each stdin line to lines and closes eof when stdin ends
// (EOF or a read error). Only the end of stdin stops the helper, so a
// garbage or overlong line is skipped rather than ending the loop the way
// bufio.Scanner's ErrTooLong would.
func readCommands(stdin io.Reader, lines chan<- string, eof chan<- struct{}) {
	defer close(eof)
	r := bufio.NewReader(stdin)
	var line []byte
	for {
		chunk, err := r.ReadSlice('\n')
		if len(line) <= maxCommandBytes {
			line = append(line, chunk...)
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		if len(line) > maxCommandBytes {
			slog.Warn("ignoring overlong command", "bytes", len(line))
		} else if len(line) > 0 {
			lines <- string(line)
		}
		line = line[:0]
		if err != nil {
			if !errors.Is(err, io.EOF) {
				slog.Warn("cannot read stdin; treating it as closed", "err", err)
			}
			return
		}
	}
}

func handleCommand(line string, w *store.Writer, retry func()) {
	fields := strings.Fields(line)
	if len(fields) == 0 {
		return
	}
	switch {
	case fields[0] == "retention" && len(fields) == 2:
		n, err := strconv.ParseInt(fields[1], 10, 64)
		if err != nil || n <= 0 {
			slog.Warn("ignoring command: retention needs a positive number of seconds", "line", line)
			return
		}
		w.SetRetention(n)
	case fields[0] == "prune" && len(fields) == 1:
		w.Prune()
	case fields[0] == "retry" && len(fields) == 1:
		retry()
	default:
		slog.Warn("ignoring unknown command", "line", line)
	}
}

// stopServers gives in-flight requests a moment to finish, then closes
// everything.
func stopServers(h *http.Server, g *grpc.Server, fresh *freshConns) {
	ctx, cancel := context.WithTimeout(context.Background(), stopTimeout)
	defer cancel()
	fresh.closeAll()
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		if h.Shutdown(ctx) != nil {
			slog.Debug("http shutdown timed out")
			h.Close()
		}
	}()
	go func() {
		defer wg.Done()
		done := make(chan struct{})
		go func() { g.GracefulStop(); close(done) }()
		select {
		case <-done:
		case <-ctx.Done():
			slog.Debug("grpc graceful stop timed out")
			g.Stop()
		}
	}()
	wg.Wait()
}

// freshConns tracks HTTP connections that have not sent a request yet.
// http.Server.Shutdown waits up to 5 s for those (clients dial spare
// connections), so they are closed first; no request is in flight on them.
type freshConns struct {
	mu    sync.Mutex
	conns map[net.Conn]bool
}

func (f *freshConns) track(c net.Conn, state http.ConnState) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if state == http.StateNew {
		f.conns[c] = true
	} else {
		delete(f.conns, c)
	}
}

func (f *freshConns) closeAll() {
	f.mu.Lock()
	defer f.mu.Unlock()
	for c := range f.conns {
		c.Close()
	}
}
