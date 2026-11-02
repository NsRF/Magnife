// Package receiver serves OTLP over HTTP and gRPC, decoding with the
// OpenTelemetry Collector's pdata packages, and hands batches to a Sink.
package receiver

import (
	"context"
	"fmt"
	"log/slog"

	"go.opentelemetry.io/collector/pdata/plog"
	"go.opentelemetry.io/collector/pdata/pmetric"
	"go.opentelemetry.io/collector/pdata/ptrace"

	"magnife/ingest/internal/convert"
	"magnife/ingest/internal/store"
)

// Sink accepts decoded batches; store.Writer implements it.
type Sink interface {
	Submit(ctx context.Context, b *store.Batch) error
}

// Receiver converts OTLP data on the request goroutine and submits it.
type Receiver struct {
	Sink Sink
}

// Traces stores the spans and returns how many were rejected and why.
func (r *Receiver) Traces(ctx context.Context, td ptrace.Traces) (rejected int, msg string, err error) {
	spans, rejected := convert.Traces(td)
	slog.Debug("export", "signal", "traces", "spans", len(spans), "rejected", rejected)
	if rejected > 0 {
		msg = fmt.Sprintf("%d spans without a trace id or span id were dropped", rejected)
	}
	return rejected, msg, r.Sink.Submit(ctx, &store.Batch{Spans: spans})
}

// Logs stores the log records.
func (r *Receiver) Logs(ctx context.Context, ld plog.Logs) error {
	logs := convert.Logs(ld)
	slog.Debug("export", "signal", "logs", "logs", len(logs))
	return r.Sink.Submit(ctx, &store.Batch{Logs: logs})
}

// Metrics drops metrics (v0.2). With -v it says whose they were, which the
// interop scripts use to check that metric exports succeed.
func (r *Receiver) Metrics(md pmetric.Metrics) {
	if !slog.Default().Enabled(context.Background(), slog.LevelDebug) {
		return
	}
	rms := md.ResourceMetrics()
	for i := 0; i < rms.Len(); i++ {
		rm := rms.At(i)
		n := 0
		for j := 0; j < rm.ScopeMetrics().Len(); j++ {
			n += rm.ScopeMetrics().At(j).Metrics().Len()
		}
		slog.Debug("dropped metrics", "service", convert.Resource(rm.Resource()).ServiceName, "metrics", n)
	}
}
