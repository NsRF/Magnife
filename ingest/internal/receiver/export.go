package receiver

import (
	"context"
	"errors"

	"go.opentelemetry.io/collector/pdata/plog/plogotlp"
	"go.opentelemetry.io/collector/pdata/pmetric/pmetricotlp"
	"go.opentelemetry.io/collector/pdata/ptrace/ptraceotlp"
)

// MaxInFlight is how many requests, HTTP and gRPC together, may read,
// decode and convert at once. Each holds up to MaxBodyBytes and its decoded
// form, so concurrent requests cannot add up to gigabytes; the others wait.
const MaxInFlight = 4

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

// message is the part of the pdata request types we need.
type message interface {
	UnmarshalProto([]byte) error
	UnmarshalJSON([]byte) error
}

type response interface {
	MarshalProto() ([]byte, error)
	MarshalJSON() ([]byte, error)
}

// badRequestError is a body that cannot be decoded: 400 or InvalidArgument.
type badRequestError struct{ msg string }

func (e *badRequestError) Error() string { return e.msg }

func isBadRequest(err error) bool {
	var bad *badRequestError
	return errors.As(err, &bad)
}

// exportFunc decodes one request body, stores what it carries and returns
// the response. A decode error is a *badRequestError; any other error means
// the store is not taking data (503 or Unavailable).
type exportFunc func(ctx context.Context, enc encoding, body []byte) (response, error)

// gate returns the shared in-flight semaphore.
func (r *Receiver) gate() chan struct{} {
	r.gateOnce.Do(func() { r.inflight = make(chan struct{}, MaxInFlight) })
	return r.inflight
}

// acquire waits for a free in-flight slot, or for ctx to end.
func (r *Receiver) acquire(ctx context.Context) (release func(), err error) {
	g := r.gate()
	select {
	case g <- struct{}{}:
		return func() { <-g }, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// decode checks how deeply the body nests, without recursion, then decodes it.
func decode(enc encoding, body []byte, root msgType, m message) error {
	var err error
	if enc == encJSON {
		err = checkJSONDepth(body)
	} else {
		err = checkProtoDepth(body, root)
	}
	if err == nil {
		if enc == encJSON {
			err = m.UnmarshalJSON(body)
		} else {
			err = m.UnmarshalProto(body)
		}
	}
	if err != nil {
		return &badRequestError{"cannot decode OTLP body: " + err.Error()}
	}
	return nil
}

func (r *Receiver) exportTraces(ctx context.Context, enc encoding, body []byte) (response, error) {
	otlp := ptraceotlp.NewExportRequest()
	if err := decode(enc, body, mTraceRequest, otlp); err != nil {
		return nil, err
	}
	rejected, msg, err := r.Traces(ctx, otlp.Traces())
	if err != nil {
		return nil, err
	}
	resp := ptraceotlp.NewExportResponse()
	if rejected > 0 {
		resp.PartialSuccess().SetRejectedSpans(int64(rejected))
		resp.PartialSuccess().SetErrorMessage(msg)
	}
	return resp, nil
}

func (r *Receiver) exportLogs(ctx context.Context, enc encoding, body []byte) (response, error) {
	otlp := plogotlp.NewExportRequest()
	if err := decode(enc, body, mLogsRequest, otlp); err != nil {
		return nil, err
	}
	if err := r.Logs(ctx, otlp.Logs()); err != nil {
		return nil, err
	}
	return plogotlp.NewExportResponse(), nil
}

// exportMetrics accepts and drops metrics (v0.2), so SDKs that export them
// by default do not log errors.
func (r *Receiver) exportMetrics(_ context.Context, enc encoding, body []byte) (response, error) {
	otlp := pmetricotlp.NewExportRequest()
	if err := decode(enc, body, mMetricsRequest, otlp); err != nil {
		return nil, err
	}
	r.Metrics(otlp.Metrics())
	return pmetricotlp.NewExportResponse(), nil
}
