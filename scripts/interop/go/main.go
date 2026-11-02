// Command interop-go sends one trace, two logs and a metric with the official
// OpenTelemetry Go SDK, configured only by the standard OTEL_* environment
// variables. OTEL_EXPORTER_OTLP_PROTOCOL picks the exporters (grpc or
// http/protobuf); the exporters read OTEL_EXPORTER_OTLP_ENDPOINT themselves.
//
// It prints one JSON line with the ids it sent and exits 1 if any export
// failed, so scripts/interop/run-all.sh can check the database against it.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sync"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	otellog "go.opentelemetry.io/otel/log"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

// errs collects export errors reported through otel's global error handler.
type errs struct {
	mu   sync.Mutex
	list []error
}

func (e *errs) Handle(err error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	fmt.Fprintf(os.Stderr, "otel error: %v\n", err)
	e.list = append(e.list, err)
}

func main() {
	failures := &errs{}
	otel.SetErrorHandler(failures)
	ctx := context.Background()

	protocol := os.Getenv("OTEL_EXPORTER_OTLP_PROTOCOL")
	if protocol == "" {
		protocol = "http/protobuf" // the spec's default
	}
	var (
		spanExp   sdktrace.SpanExporter
		logExp    sdklog.Exporter
		metricExp sdkmetric.Exporter
		err       error
	)
	switch protocol {
	case "grpc":
		spanExp, err = otlptracegrpc.New(ctx)
		if err == nil {
			logExp, err = otlploggrpc.New(ctx)
		}
		if err == nil {
			metricExp, err = otlpmetricgrpc.New(ctx)
		}
	case "http/protobuf":
		spanExp, err = otlptracehttp.New(ctx)
		if err == nil {
			logExp, err = otlploghttp.New(ctx)
		}
		if err == nil {
			metricExp, err = otlpmetrichttp.New(ctx)
		}
	default:
		err = fmt.Errorf("OTEL_EXPORTER_OTLP_PROTOCOL %q: the Go SDK supports grpc and http/protobuf", protocol)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	// resource.Default reads OTEL_SERVICE_NAME and OTEL_RESOURCE_ATTRIBUTES.
	res := resource.Default()
	tp := sdktrace.NewTracerProvider(sdktrace.WithResource(res), sdktrace.WithBatcher(spanExp))
	lp := sdklog.NewLoggerProvider(sdklog.WithResource(res), sdklog.WithProcessor(sdklog.NewBatchProcessor(logExp)))
	mp := sdkmetric.NewMeterProvider(sdkmetric.WithResource(res),
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExp, sdkmetric.WithInterval(time.Hour))))

	tracer := tp.Tracer("magnife-interop")
	logger := lp.Logger("magnife-interop")
	counter, _ := mp.Meter("magnife-interop").Int64Counter("interop.requests")

	emit := func(ctx context.Context, sev otellog.Severity, text, body string) {
		var r otellog.Record
		r.SetTimestamp(time.Now())
		r.SetSeverity(sev)
		r.SetSeverityText(text)
		r.SetBody(attribute.StringValue(body))
		r.AddAttributes(attribute.String("interop.sdk", "go"))
		logger.Emit(ctx, r)
	}

	rootCtx, root := tracer.Start(ctx, "GET /orders/{id}", trace.WithSpanKind(trace.SpanKindServer),
		trace.WithAttributes(
			attribute.String("http.request.method", "GET"),
			attribute.String("http.route", "/orders/{id}"),
			attribute.String("url.path", "/orders/42"),
			attribute.Int("http.response.status_code", 200)))
	dbCtx, db := tracer.Start(rootCtx, "SELECT orders", trace.WithSpanKind(trace.SpanKindClient),
		trace.WithAttributes(
			attribute.String("db.system.name", "postgresql"),
			attribute.String("db.query.text", "SELECT * FROM orders WHERE id = $1")))
	emit(dbCtx, otellog.SeverityInfo, "INFO", "loading order 42")
	time.Sleep(5 * time.Millisecond)
	db.End()
	_, call := tracer.Start(rootCtx, "POST", trace.WithSpanKind(trace.SpanKindClient),
		trace.WithAttributes(
			attribute.String("http.request.method", "POST"),
			attribute.String("url.full", "http://payments.local/charge"),
			attribute.Int("http.response.status_code", 500)))
	call.RecordError(errors.New("payment service returned 500"), trace.WithStackTrace(true))
	call.SetStatus(codes.Error, "HTTP 500")
	call.End()
	counter.Add(rootCtx, 1)
	root.End()
	emit(ctx, otellog.SeverityWarn, "WARN", "interop run finished")

	ids := map[string]string{
		"trace_id":     root.SpanContext().TraceID().String(),
		"root_span_id": root.SpanContext().SpanID().String(),
		"db_span_id":   db.SpanContext().SpanID().String(),
		"call_span_id": call.SpanContext().SpanID().String(),
	}

	// Shutdown flushes; export errors come back here or through the handler.
	sctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	for _, shut := range []func(context.Context) error{tp.Shutdown, lp.Shutdown, mp.Shutdown} {
		if err := shut(sctx); err != nil {
			failures.Handle(err)
		}
	}
	line, _ := json.Marshal(ids)
	fmt.Println(string(line))
	if len(failures.list) > 0 {
		os.Exit(1)
	}
}
