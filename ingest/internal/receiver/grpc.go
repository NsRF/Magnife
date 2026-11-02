package receiver

import (
	"context"

	"go.opentelemetry.io/collector/pdata/plog/plogotlp"
	"go.opentelemetry.io/collector/pdata/pmetric/pmetricotlp"
	"go.opentelemetry.io/collector/pdata/ptrace/ptraceotlp"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	_ "google.golang.org/grpc/encoding/gzip" // registers the gzip compressor exporters use
	"google.golang.org/grpc/status"
)

// MaxGRPCMessageBytes raises gRPC's 4 MiB default so large exports fit.
const MaxGRPCMessageBytes = 64 << 20

// NewGRPCServer returns a server with the OTLP trace, logs and metrics services.
func (r *Receiver) NewGRPCServer() *grpc.Server {
	s := grpc.NewServer(grpc.MaxRecvMsgSize(MaxGRPCMessageBytes))
	ptraceotlp.RegisterGRPCServer(s, &traceService{r: r})
	plogotlp.RegisterGRPCServer(s, &logsService{r: r})
	pmetricotlp.RegisterGRPCServer(s, &metricsService{r: r})
	return s
}

type traceService struct {
	ptraceotlp.UnimplementedGRPCServer
	r *Receiver
}

func (t *traceService) Export(ctx context.Context, req ptraceotlp.ExportRequest) (ptraceotlp.ExportResponse, error) {
	rejected, msg, err := t.r.Traces(ctx, req.Traces())
	if err != nil {
		return ptraceotlp.NewExportResponse(), status.Error(codes.Unavailable, err.Error())
	}
	resp := ptraceotlp.NewExportResponse()
	if rejected > 0 {
		resp.PartialSuccess().SetRejectedSpans(int64(rejected))
		resp.PartialSuccess().SetErrorMessage(msg)
	}
	return resp, nil
}

type logsService struct {
	plogotlp.UnimplementedGRPCServer
	r *Receiver
}

func (l *logsService) Export(ctx context.Context, req plogotlp.ExportRequest) (plogotlp.ExportResponse, error) {
	if err := l.r.Logs(ctx, req.Logs()); err != nil {
		return plogotlp.NewExportResponse(), status.Error(codes.Unavailable, err.Error())
	}
	return plogotlp.NewExportResponse(), nil
}

// metricsService accepts and drops metrics.
type metricsService struct {
	pmetricotlp.UnimplementedGRPCServer
	r *Receiver
}

func (m *metricsService) Export(_ context.Context, req pmetricotlp.ExportRequest) (pmetricotlp.ExportResponse, error) {
	m.r.Metrics(req.Metrics())
	return pmetricotlp.NewExportResponse(), nil
}
