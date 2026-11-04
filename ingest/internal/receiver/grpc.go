package receiver

import (
	"context"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	grpcencoding "google.golang.org/grpc/encoding"
	_ "google.golang.org/grpc/encoding/gzip" // registers the gzip compressor exporters use
	"google.golang.org/grpc/mem"
	"google.golang.org/grpc/status"
)

// MaxGRPCMessageBytes caps one message after decompression, like MaxBodyBytes.
const MaxGRPCMessageBytes = MaxBodyBytes

// maxStreamsPerConn bounds the messages one connection can have read but
// not yet decoded (each up to MaxGRPCMessageBytes) while they wait for the
// in-flight gate.
const maxStreamsPerConn = 2 * MaxInFlight

// NewGRPCServer returns a server with the OTLP trace, logs and metrics
// services. They are registered here rather than through pdata's
// RegisterGRPCServer so each request arrives as bytes: the nesting check and
// the in-flight gate run before decoding, as on HTTP, and a refused request
// gets InvalidArgument.
func (r *Receiver) NewGRPCServer() *grpc.Server {
	s := grpc.NewServer(
		grpc.MaxRecvMsgSize(MaxGRPCMessageBytes),
		grpc.MaxConcurrentStreams(maxStreamsPerConn),
		grpc.ForceServerCodecV2(rawCodec{delegate: grpcencoding.GetCodecV2("proto")}),
	)
	for _, svc := range []struct {
		name, file string
		export     exportFunc
	}{
		{"opentelemetry.proto.collector.trace.v1.TraceService", "opentelemetry/proto/collector/trace/v1/trace_service.proto", r.exportTraces},
		{"opentelemetry.proto.collector.logs.v1.LogsService", "opentelemetry/proto/collector/logs/v1/logs_service.proto", r.exportLogs},
		{"opentelemetry.proto.collector.metrics.v1.MetricsService", "opentelemetry/proto/collector/metrics/v1/metrics_service.proto", r.exportMetrics},
	} {
		s.RegisterService(&grpc.ServiceDesc{
			ServiceName: svc.name,
			HandlerType: (*any)(nil),
			Methods:     []grpc.MethodDesc{{MethodName: "Export", Handler: r.grpcHandler(svc.export)}},
			Metadata:    svc.file,
		}, r)
	}
	return s
}

func (r *Receiver) grpcHandler(export exportFunc) grpc.MethodHandler {
	return func(_ any, ctx context.Context, dec func(any) error, _ grpc.UnaryServerInterceptor) (any, error) {
		var in rawMessage
		if err := dec(&in); err != nil {
			return nil, err
		}
		release, err := r.acquire(ctx)
		if err != nil {
			return nil, status.FromContextError(err).Err()
		}
		defer release()
		resp, err := export(ctx, encProto, in.b)
		switch {
		case isBadRequest(err):
			return nil, status.Error(codes.InvalidArgument, err.Error())
		case err != nil:
			return nil, status.Error(codes.Unavailable, err.Error())
		}
		b, err := resp.MarshalProto()
		if err != nil {
			return nil, status.Error(codes.Internal, err.Error())
		}
		return &rawMessage{b}, nil
	}
}

// rawMessage is a request or response as protobuf bytes.
type rawMessage struct{ b []byte }

// rawCodec passes rawMessage bytes through and leaves anything else to the
// registered proto codec.
type rawCodec struct{ delegate grpcencoding.CodecV2 }

func (c rawCodec) Marshal(v any) (mem.BufferSlice, error) {
	if m, ok := v.(*rawMessage); ok {
		return mem.BufferSlice{mem.SliceBuffer(m.b)}, nil
	}
	return c.delegate.Marshal(v)
}

func (c rawCodec) Unmarshal(data mem.BufferSlice, v any) error {
	if m, ok := v.(*rawMessage); ok {
		m.b = data.Materialize() // a copy: gRPC frees data afterwards
		return nil
	}
	return c.delegate.Unmarshal(data, v)
}

func (rawCodec) Name() string { return "proto" }
