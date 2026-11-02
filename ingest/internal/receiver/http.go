package receiver

import (
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"strings"

	"go.opentelemetry.io/collector/pdata/plog/plogotlp"
	"go.opentelemetry.io/collector/pdata/pmetric/pmetricotlp"
	"go.opentelemetry.io/collector/pdata/ptrace/ptraceotlp"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

// MaxBodyBytes caps a decompressed request body.
const MaxBodyBytes = 128 << 20

type encoding int

const (
	encProto encoding = iota
	encJSON
)

func (e encoding) contentType() string {
	if e == encJSON {
		return "application/json"
	}
	return "application/x-protobuf"
}

// message is the part of the pdata request and response types we need.
type message interface {
	UnmarshalProto([]byte) error
	UnmarshalJSON([]byte) error
}

type response interface {
	MarshalProto() ([]byte, error)
	MarshalJSON() ([]byte, error)
}

// HTTPHandler serves POST /v1/traces, /v1/logs and /v1/metrics.
func (r *Receiver) HTTPHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/traces", func(w http.ResponseWriter, req *http.Request) {
		otlp := ptraceotlp.NewExportRequest()
		enc, body, ok := readRequest(w, req)
		if !ok || !decode(w, enc, body, otlp) {
			return
		}
		rejected, msg, err := r.Traces(req.Context(), otlp.Traces())
		if err != nil {
			writeStatus(w, enc, http.StatusServiceUnavailable, codes.Unavailable, err.Error())
			return
		}
		resp := ptraceotlp.NewExportResponse()
		if rejected > 0 {
			resp.PartialSuccess().SetRejectedSpans(int64(rejected))
			resp.PartialSuccess().SetErrorMessage(msg)
		}
		writeResponse(w, enc, resp)
	})
	mux.HandleFunc("/v1/logs", func(w http.ResponseWriter, req *http.Request) {
		otlp := plogotlp.NewExportRequest()
		enc, body, ok := readRequest(w, req)
		if !ok || !decode(w, enc, body, otlp) {
			return
		}
		if err := r.Logs(req.Context(), otlp.Logs()); err != nil {
			writeStatus(w, enc, http.StatusServiceUnavailable, codes.Unavailable, err.Error())
			return
		}
		writeResponse(w, enc, plogotlp.NewExportResponse())
	})
	// Metrics are accepted and dropped (v0.2), so SDKs that export them by
	// default do not log errors.
	mux.HandleFunc("/v1/metrics", func(w http.ResponseWriter, req *http.Request) {
		otlp := pmetricotlp.NewExportRequest()
		enc, body, ok := readRequest(w, req)
		if !ok || !decode(w, enc, body, otlp) {
			return
		}
		r.Metrics(otlp.Metrics())
		writeResponse(w, enc, pmetricotlp.NewExportResponse())
	})
	return mux
}

// readRequest checks method, content type and encoding, and reads the body.
func readRequest(w http.ResponseWriter, req *http.Request) (encoding, []byte, bool) {
	if req.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed; use POST", http.StatusMethodNotAllowed)
		return 0, nil, false
	}
	mediaType, _, _ := mime.ParseMediaType(req.Header.Get("Content-Type"))
	var enc encoding
	switch mediaType {
	case "application/x-protobuf", "application/protobuf":
		enc = encProto
	case "application/json":
		enc = encJSON
	default:
		http.Error(w, fmt.Sprintf("unsupported content type %q; use application/x-protobuf or application/json",
			req.Header.Get("Content-Type")), http.StatusUnsupportedMediaType)
		return 0, nil, false
	}

	var src io.Reader = req.Body
	switch ce := strings.ToLower(strings.TrimSpace(req.Header.Get("Content-Encoding"))); ce {
	case "", "identity":
	case "gzip":
		zr, err := gzip.NewReader(req.Body)
		if err != nil {
			writeStatus(w, enc, http.StatusBadRequest, codes.InvalidArgument, "invalid gzip body: "+err.Error())
			return 0, nil, false
		}
		defer zr.Close()
		src = zr
	default:
		writeStatus(w, enc, http.StatusUnsupportedMediaType, codes.InvalidArgument,
			fmt.Sprintf("unsupported content encoding %q; use gzip or none", ce))
		return 0, nil, false
	}

	var buf bytes.Buffer
	n, err := buf.ReadFrom(io.LimitReader(src, MaxBodyBytes+1))
	if err != nil {
		writeStatus(w, enc, http.StatusBadRequest, codes.InvalidArgument, "cannot read body: "+err.Error())
		return 0, nil, false
	}
	if n > MaxBodyBytes {
		writeStatus(w, enc, http.StatusRequestEntityTooLarge, codes.InvalidArgument, "body is larger than 128 MiB")
		return 0, nil, false
	}
	return enc, buf.Bytes(), true
}

func decode(w http.ResponseWriter, enc encoding, body []byte, m message) bool {
	var err error
	if enc == encJSON {
		err = m.UnmarshalJSON(body)
	} else {
		err = m.UnmarshalProto(body)
	}
	if err != nil {
		writeStatus(w, enc, http.StatusBadRequest, codes.InvalidArgument, "cannot decode OTLP body: "+err.Error())
		return false
	}
	return true
}

func writeResponse(w http.ResponseWriter, enc encoding, resp response) {
	var (
		b   []byte
		err error
	)
	if enc == encJSON {
		b, err = resp.MarshalJSON()
	} else {
		b, err = resp.MarshalProto()
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", enc.contentType())
	w.WriteHeader(http.StatusOK)
	w.Write(b)
}

// writeStatus replies with a google.rpc.Status in the request's encoding, as
// the OTLP/HTTP spec asks for errors.
func writeStatus(w http.ResponseWriter, enc encoding, httpCode int, code codes.Code, msg string) {
	slog.Debug("otlp http error", "status", httpCode, "message", msg)
	st := status.New(code, msg).Proto()
	var b []byte
	if enc == encJSON {
		b, _ = protojson.Marshal(st)
	} else {
		b, _ = proto.Marshal(st)
	}
	w.Header().Set("Content-Type", enc.contentType())
	w.WriteHeader(httpCode)
	w.Write(b)
}
