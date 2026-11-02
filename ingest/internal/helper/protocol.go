package helper

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"sync"

	"magnife/ingest/internal/store"
)

// Stdout lines, in the shapes of "Helper protocol" in docs/schema.sql.

type portState struct {
	Addr  string `json:"addr"`
	State string `json:"state"` // "listening" or "busy"
	Owner string `json:"owner,omitempty"`
	PID   int    `json:"pid,omitempty"`
}

type portsLine struct {
	Type string    `json:"type"`
	GRPC portState `json:"grpc"`
	HTTP portState `json:"http"`
}

type batchLine struct {
	Type        string   `json:"type"`
	Seq         int64    `json:"seq"`
	Spans       int      `json:"spans"`
	Logs        int      `json:"logs"`
	Traces      []string `json:"traces"`
	ErrorTraces []string `json:"error_traces"`
}

type prunedLine struct {
	Type   string `json:"type"`
	Traces int64  `json:"traces"`
	Spans  int64  `json:"spans"`
	Logs   int64  `json:"logs"`
}

type errorLine struct {
	Type    string `json:"type"`
	Message string `json:"message"`
}

// emitter writes one JSON object per line. Each line is a single Write, so
// it reaches the pipe at once and lines never interleave.
type emitter struct {
	mu     sync.Mutex
	w      io.Writer
	broken chan struct{} // closed when stdout fails (the app is gone)
	once   sync.Once
}

func newEmitter(w io.Writer) *emitter { return &emitter{w: w, broken: make(chan struct{})} }

func (e *emitter) emit(v any) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil { // Encode adds the newline
		return
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if _, err := e.w.Write(buf.Bytes()); err != nil {
		e.once.Do(func() { close(e.broken) })
	}
}

func (e *emitter) ports(grpc, http portState) {
	e.emit(portsLine{Type: "ports", GRPC: grpc, HTTP: http})
}

func (e *emitter) errorf(msg string) { e.emit(errorLine{Type: "error", Message: msg}) }

// Batch, Pruned and Error implement store.Events.

func (e *emitter) Batch(r store.BatchResult) {
	e.emit(batchLine{Type: "batch", Seq: r.Seq, Spans: r.Spans, Logs: r.Logs, Traces: r.Traces, ErrorTraces: r.ErrorTraces})
}

func (e *emitter) Pruned(r store.PruneResult) {
	e.emit(prunedLine{Type: "pruned", Traces: r.Traces, Spans: r.Spans, Logs: r.Logs})
}

func (e *emitter) Error(err error) {
	slog.Error("database write failed", "err", err)
	e.errorf(err.Error())
}
