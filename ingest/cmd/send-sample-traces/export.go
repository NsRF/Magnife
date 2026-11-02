package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"net/http"
	"sync/atomic"
	"time"

	"go.opentelemetry.io/collector/pdata/plog"
	"go.opentelemetry.io/collector/pdata/plog/plogotlp"
	"go.opentelemetry.io/collector/pdata/ptrace"
	"go.opentelemetry.io/collector/pdata/ptrace/ptraceotlp"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	_ "google.golang.org/grpc/encoding/gzip"
)

// exporter sends one OTLP request.
type exporter interface {
	Traces(ctx context.Context, td ptrace.Traces) error
	Logs(ctx context.Context, ld plog.Logs) error
	Name() string
}

// httpExporter speaks OTLP/HTTP with protobuf or JSON bodies.
type httpExporter struct {
	base   string
	json   bool
	gzip   bool
	client *http.Client
}

func (h *httpExporter) Name() string {
	n := "http-protobuf"
	if h.json {
		n = "http-json"
	}
	if h.gzip {
		n += "+gzip"
	}
	return n
}

func (h *httpExporter) Traces(ctx context.Context, td ptrace.Traces) error {
	req := ptraceotlp.NewExportRequestFromTraces(td)
	var body []byte
	var err error
	if h.json {
		body, err = req.MarshalJSON()
	} else {
		body, err = req.MarshalProto()
	}
	if err != nil {
		return err
	}
	return h.post(ctx, "/v1/traces", body)
}

func (h *httpExporter) Logs(ctx context.Context, ld plog.Logs) error {
	req := plogotlp.NewExportRequestFromLogs(ld)
	var body []byte
	var err error
	if h.json {
		body, err = req.MarshalJSON()
	} else {
		body, err = req.MarshalProto()
	}
	if err != nil {
		return err
	}
	return h.post(ctx, "/v1/logs", body)
}

func (h *httpExporter) post(ctx context.Context, path string, body []byte) error {
	if h.gzip {
		var buf bytes.Buffer
		zw := gzip.NewWriter(&buf)
		zw.Write(body)
		zw.Close()
		body = buf.Bytes()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.base+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	if h.json {
		req.Header.Set("Content-Type", "application/json")
	} else {
		req.Header.Set("Content-Type", "application/x-protobuf")
	}
	if h.gzip {
		req.Header.Set("Content-Encoding", "gzip")
	}
	resp, err := h.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s %s: HTTP %d: %q", h.Name(), path, resp.StatusCode, msg)
	}
	return nil
}

// grpcExporter speaks OTLP/gRPC.
type grpcExporter struct {
	traces ptraceotlp.GRPCClient
	logs   plogotlp.GRPCClient
	opts   []grpc.CallOption
	gzip   bool
}

func newGRPCExporter(addr string, gz bool) (*grpcExporter, error) {
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultCallOptions(grpc.MaxCallSendMsgSize(64<<20)))
	if err != nil {
		return nil, err
	}
	e := &grpcExporter{traces: ptraceotlp.NewGRPCClient(conn), logs: plogotlp.NewGRPCClient(conn), gzip: gz}
	if gz {
		e.opts = append(e.opts, grpc.UseCompressor("gzip"))
	}
	return e, nil
}

func (g *grpcExporter) Name() string {
	if g.gzip {
		return "grpc+gzip"
	}
	return "grpc"
}

func (g *grpcExporter) Traces(ctx context.Context, td ptrace.Traces) error {
	_, err := g.traces.Export(ctx, ptraceotlp.NewExportRequestFromTraces(td), g.opts...)
	return err
}

func (g *grpcExporter) Logs(ctx context.Context, ld plog.Logs) error {
	_, err := g.logs.Export(ctx, plogotlp.NewExportRequestFromLogs(ld), g.opts...)
	return err
}

// mixedExporter rotates through several exporters, one request each.
type mixedExporter struct {
	list []exporter
	n    atomic.Uint64
}

func (m *mixedExporter) next() exporter { return m.list[(m.n.Add(1)-1)%uint64(len(m.list))] }
func (m *mixedExporter) Name() string   { return "mixed" }

func (m *mixedExporter) Traces(ctx context.Context, td ptrace.Traces) error {
	return m.next().Traces(ctx, td)
}

func (m *mixedExporter) Logs(ctx context.Context, ld plog.Logs) error {
	return m.next().Logs(ctx, ld)
}

func newExporter(protocol, httpAddr, grpcAddr string, gz bool) (exporter, error) {
	client := &http.Client{Timeout: 30 * time.Second, Transport: &http.Transport{MaxIdleConnsPerHost: 32}}
	base := "http://" + httpAddr
	switch protocol {
	case "http-protobuf":
		return &httpExporter{base: base, gzip: gz, client: client}, nil
	case "http-json":
		return &httpExporter{base: base, json: true, gzip: gz, client: client}, nil
	case "grpc":
		return newGRPCExporter(grpcAddr, gz)
	case "mixed":
		gzipped, err := newGRPCExporter(grpcAddr, true)
		if err != nil {
			return nil, err
		}
		plain, err := newGRPCExporter(grpcAddr, false)
		if err != nil {
			return nil, err
		}
		// Every encoding, with and without gzip.
		return &mixedExporter{list: []exporter{
			&httpExporter{base: base, gzip: true, client: client},
			&httpExporter{base: base, json: true, client: client},
			gzipped,
			&httpExporter{base: base, client: client},
			&httpExporter{base: base, json: true, gzip: true, client: client},
			plain,
		}}, nil
	}
	return nil, fmt.Errorf("unknown --protocol %q (use http-protobuf, http-json, grpc or mixed)", protocol)
}
