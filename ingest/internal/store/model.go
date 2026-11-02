package store

import "database/sql"

// Resource is one OTLP resource, already encoded.
type Resource struct {
	Hash        string // sha256 hex of Attributes
	ServiceName string
	Attributes  string // canonical JSON object (sorted keys)
	Keys        []string
}

// Span is one span row, ready to insert.
type Span struct {
	Resource      *Resource
	TraceID       string
	SpanID        string
	ParentSpanID  string // "" is stored as NULL
	Name          string
	Kind          int32
	StartNs       int64
	EndNs         int64
	StatusCode    int32
	StatusMessage string
	ScopeName     string
	ScopeVersion  string
	Attributes    string
	Events        string
	Links         string
	AttrKeys      []string

	DBSystem       sql.NullString
	DBStatement    sql.NullString
	HTTPMethod     sql.NullString
	HTTPStatusCode sql.NullInt64
	HTTPRoute      sql.NullString
	HTTPURL        sql.NullString
}

// Log is one log row, ready to insert.
type Log struct {
	Resource       *Resource
	TimeNs         int64 // 0 means "use ObservedNs, else the receive time"
	ObservedNs     int64
	SeverityNumber int32
	SeverityText   string
	ScopeName      string
	Body           string
	Attributes     string
	AttrKeys       []string
	TraceID        string // "" is stored as NULL
	SpanID         string // "" is stored as NULL
	EventName      string
}

// Batch is what one export request hands to the writer.
type Batch struct {
	Spans []Span
	Logs  []Log
}

// Len counts records toward the batch size limit.
func (b *Batch) Len() int { return len(b.Spans) + len(b.Logs) }

// BatchResult describes one committed batch (the "batch" stdout line).
type BatchResult struct {
	Seq         int64
	Spans       int
	Logs        int
	Traces      []string
	ErrorTraces []string
}

// PruneResult counts rows deleted by pruning (the "pruned" stdout line).
type PruneResult struct {
	Traces int64
	Spans  int64
	Logs   int64
}

// Add accumulates another chunk's counts.
func (p *PruneResult) Add(o PruneResult) {
	p.Traces += o.Traces
	p.Spans += o.Spans
	p.Logs += o.Logs
}

// Empty reports whether nothing was deleted.
func (p PruneResult) Empty() bool { return p.Traces == 0 && p.Spans == 0 && p.Logs == 0 }

func nullIfEmpty(s string) sql.NullString { return sql.NullString{String: s, Valid: s != ""} }
