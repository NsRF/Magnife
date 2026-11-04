package receiver

import (
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

// MaxBodyBytes caps a request body, before and after decompression. Real
// exports are far smaller (30,000 spans are about 10 MB); a larger cap let a
// handful of concurrent requests take gigabytes.
const MaxBodyBytes = 32 << 20

// HTTPHandler serves POST /v1/traces, /v1/logs and /v1/metrics, to requests
// addressed to this Mac only (localOnly).
func (r *Receiver) HTTPHandler() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("/v1/traces", r.serveHTTP(r.exportTraces))
	mux.Handle("/v1/logs", r.serveHTTP(r.exportLogs))
	mux.Handle("/v1/metrics", r.serveHTTP(r.exportMetrics))
	return localOnly(mux)
}

func (r *Receiver) serveHTTP(export exportFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		enc, ok := checkRequest(w, req)
		if !ok {
			return
		}
		release, err := r.acquire(req.Context())
		if err != nil {
			return // the client went away while waiting
		}
		defer release()
		body, ok := readBody(w, req, enc)
		if !ok {
			return
		}
		resp, err := export(req.Context(), enc, body)
		switch {
		case isBadRequest(err):
			writeStatus(w, enc, http.StatusBadRequest, codes.InvalidArgument, err.Error())
		case err != nil:
			writeStatus(w, enc, http.StatusServiceUnavailable, codes.Unavailable, err.Error())
		default:
			writeResponse(w, enc, resp)
		}
	})
}

// localOnly refuses requests whose Host, or Origin when there is one, is
// not this Mac: a web page that rebinds its own domain to 127.0.0.1 could
// otherwise post to the receiver (DNS rebinding).
func localOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if !isLocalHost(req.Host) {
			http.Error(w, fmt.Sprintf("host %q is not this Mac; send to localhost or 127.0.0.1", req.Host), http.StatusForbidden)
			return
		}
		if origin := req.Header.Get("Origin"); origin != "" {
			u, err := url.Parse(origin)
			if err != nil || u.Host == "" || !isLocalHost(u.Host) {
				http.Error(w, fmt.Sprintf("requests from %q are not accepted", origin), http.StatusForbidden)
				return
			}
		}
		next.ServeHTTP(w, req)
	})
}

// isLocalHost reports whether a Host header (with or without a port) names
// this Mac: localhost, a loopback address, or the name Docker containers use
// for it. An empty Host (HTTP/1.0) passes; browsers always send one.
func isLocalHost(hostport string) bool {
	host := hostport
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		host = h
	}
	host = strings.TrimSuffix(strings.TrimPrefix(host, "["), "]")
	switch strings.ToLower(strings.TrimSuffix(host, ".")) {
	case "", "localhost", "host.docker.internal":
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// checkRequest checks method, content type and declared length.
func checkRequest(w http.ResponseWriter, req *http.Request) (encoding, bool) {
	if req.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed; use POST", http.StatusMethodNotAllowed)
		return 0, false
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
		return 0, false
	}
	if req.ContentLength > MaxBodyBytes {
		writeStatus(w, enc, http.StatusRequestEntityTooLarge, codes.InvalidArgument, tooLarge)
		return 0, false
	}
	return enc, true
}

var tooLarge = fmt.Sprintf("body is larger than %d MiB", MaxBodyBytes>>20)

// readBody decompresses and reads the body, at most MaxBodyBytes.
func readBody(w http.ResponseWriter, req *http.Request, enc encoding) ([]byte, bool) {
	var src io.Reader = http.MaxBytesReader(w, req.Body, MaxBodyBytes)
	switch ce := strings.ToLower(strings.TrimSpace(req.Header.Get("Content-Encoding"))); ce {
	case "", "identity":
	case "gzip":
		zr, err := gzip.NewReader(src)
		if err != nil {
			writeStatus(w, enc, http.StatusBadRequest, codes.InvalidArgument, "invalid gzip body: "+err.Error())
			return nil, false
		}
		defer zr.Close()
		src = zr
	default:
		writeStatus(w, enc, http.StatusUnsupportedMediaType, codes.InvalidArgument,
			fmt.Sprintf("unsupported content encoding %q; use gzip or none", ce))
		return nil, false
	}

	body, err := readLimited(src, MaxBodyBytes)
	var tooBig *http.MaxBytesError
	switch {
	case errors.Is(err, errTooLarge) || errors.As(err, &tooBig):
		writeStatus(w, enc, http.StatusRequestEntityTooLarge, codes.InvalidArgument, tooLarge)
		return nil, false
	case err != nil:
		writeStatus(w, enc, http.StatusBadRequest, codes.InvalidArgument, "cannot read body: "+err.Error())
		return nil, false
	}
	return body, true
}

var errTooLarge = errors.New("body too large")

// chunks are the reusable pieces readLimited reads into.
var chunks = sync.Pool{New: func() any { b := make([]byte, 1<<20); return &b }}

// readLimited reads all of src into one slice of exactly its size, or fails
// with errTooLarge past limit bytes. It reads into pooled 1 MiB chunks and
// copies once, where a growing bytes.Buffer left up to twice the body in
// garbage per request (a gzip body that inflates past the cap took 3 GB
// with eight at once).
func readLimited(src io.Reader, limit int) ([]byte, error) {
	var parts []*[]byte
	defer func() {
		for _, p := range parts {
			chunks.Put(p)
		}
	}()
	total := 0
	for {
		p := chunks.Get().(*[]byte)
		parts = append(parts, p)
		n, err := io.ReadFull(src, *p)
		total += n
		if total > limit {
			return nil, errTooLarge
		}
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			break
		}
		if err != nil {
			return nil, err
		}
	}
	out := make([]byte, 0, total)
	for _, p := range parts {
		out = append(out, (*p)[:min(len(*p), total-len(out))]...)
	}
	return out, nil
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
