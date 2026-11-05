package receiver

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"go.opentelemetry.io/collector/pdata/plog/plogotlp"
	"go.opentelemetry.io/collector/pdata/ptrace/ptraceotlp"

	"magnife/ingest/internal/convert"
	"magnife/ingest/internal/store"
)

// MaxImportBytes caps a file given to ImportFile. A 30,000-span trace with
// its logs exports to about 15 MB of JSON.
const MaxImportBytes = 64 << 20

// Syncer is a Sink that can wait until what was submitted is committed;
// store.Writer implements it.
type Syncer interface {
	Sync(ctx context.Context) error
}

// ImportResult is what one imported file held.
type ImportResult struct {
	Spans    int
	Logs     int
	Traces   []string // distinct trace ids, in the order the file has them
	Rejected int      // spans without a trace id or span id
}

// ImportFile stores the spans and logs of an OTLP JSON file: one
// ExportTraceServiceRequest or ExportLogsServiceRequest as a whole document,
// or one per line (JSON Lines, as Magnife's File > Export Trace… writes and
// the Collector's file exporter and otlpjsonfile receiver use). Metrics lines
// are skipped. It returns once the records are committed when the sink is a
// Syncer, so the app can open the traces at once. Errors are sentences for
// people: the app shows them in an alert.
func (r *Receiver) ImportFile(ctx context.Context, path string) (ImportResult, error) {
	data, err := readImportFile(path)
	if err != nil {
		return ImportResult{}, err
	}
	docs, err := splitDocuments(data)
	if err != nil {
		return ImportResult{}, err
	}

	var (
		res  ImportResult
		b    store.Batch
		seen = map[string]bool{}
	)
	for _, d := range docs {
		var probe struct {
			Spans   json.RawMessage `json:"resourceSpans"`
			Logs    json.RawMessage `json:"resourceLogs"`
			Metrics json.RawMessage `json:"resourceMetrics"`
		}
		if err := checkJSONDepth(d.body); err != nil {
			return ImportResult{}, fmt.Errorf("%s nests too deeply to be OTLP JSON.", d.where)
		}
		if err := json.Unmarshal(d.body, &probe); err != nil {
			return ImportResult{}, fmt.Errorf("%s is not a JSON object: %v.", d.where, err)
		}
		if probe.Spans == nil && probe.Logs == nil && probe.Metrics == nil {
			return ImportResult{}, fmt.Errorf("%s has no resourceSpans or resourceLogs, so it is not OTLP JSON.", d.where)
		}
		if probe.Spans != nil {
			req := ptraceotlp.NewExportRequest()
			if err := req.UnmarshalJSON(d.body); err != nil {
				return ImportResult{}, fmt.Errorf("%s has spans that cannot be read: %v.", d.where, err)
			}
			spans, rejected := convert.Traces(req.Traces())
			res.Rejected += rejected
			for _, s := range spans {
				if !seen[s.TraceID] {
					seen[s.TraceID] = true
					res.Traces = append(res.Traces, s.TraceID)
				}
			}
			b.Spans = append(b.Spans, spans...)
		}
		if probe.Logs != nil {
			req := plogotlp.NewExportRequest()
			if err := req.UnmarshalJSON(d.body); err != nil {
				return ImportResult{}, fmt.Errorf("%s has logs that cannot be read: %v.", d.where, err)
			}
			b.Logs = append(b.Logs, convert.Logs(req.Logs())...)
		}
	}
	res.Spans, res.Logs = len(b.Spans), len(b.Logs)
	if b.Len() == 0 {
		return ImportResult{}, errors.New("The file has no spans or logs.")
	}
	if err := r.Sink.Submit(ctx, &b); err != nil {
		return ImportResult{}, fmt.Errorf("Magnife could not store the file: %v.", err)
	}
	if s, ok := r.Sink.(Syncer); ok {
		if err := s.Sync(ctx); err != nil {
			return ImportResult{}, fmt.Errorf("Magnife could not store the file: %v.", err)
		}
	}
	return res, nil
}

func readImportFile(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, errors.New("The file does not exist.")
		}
		if errors.Is(err, os.ErrPermission) {
			return nil, errors.New("Magnife is not allowed to read the file.")
		}
		return nil, fmt.Errorf("The file cannot be opened: %v.", err)
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, fmt.Errorf("The file cannot be read: %v.", err)
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("This is not a regular file.")
	}
	// Read one byte past the cap, so a file that grew after Stat still fails.
	data, err := io.ReadAll(io.LimitReader(f, MaxImportBytes+1))
	if err != nil {
		return nil, fmt.Errorf("The file cannot be read: %v.", err)
	}
	if len(data) > MaxImportBytes {
		return nil, fmt.Errorf("The file is larger than %d MB.", MaxImportBytes>>20)
	}
	return data, nil
}

type document struct {
	where string // "The file" or "Line 3", for messages
	body  []byte
}

// splitDocuments returns the file as one JSON document when it is one
// (pretty-printed or not), else as one document per non-empty line.
func splitDocuments(data []byte) ([]document, error) {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 {
		return nil, errors.New("The file is empty.")
	}
	if json.Valid(trimmed) {
		return []document{{where: "The file", body: trimmed}}, nil
	}
	var docs []document
	for i, line := range bytes.Split(data, []byte("\n")) {
		line = bytes.TrimSpace(line)
		if len(line) == 0 {
			continue
		}
		where := fmt.Sprintf("Line %d", i+1)
		if !json.Valid(line) {
			return nil, fmt.Errorf("%s is not valid JSON. Magnife imports OTLP JSON: one request, or one per line.", where)
		}
		docs = append(docs, document{where: where, body: line})
	}
	return docs, nil
}
