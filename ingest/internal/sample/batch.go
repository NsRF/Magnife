// Package sample builds realistic OTLP traces and logs for three services
// (checkout-api in .NET, orders in Go, web in Node). The sample sender and the
// tests use it.
package sample

import (
	"encoding/binary"
	"math/rand/v2"
	"time"

	"go.opentelemetry.io/collector/pdata/pcommon"
	"go.opentelemetry.io/collector/pdata/plog"
	"go.opentelemetry.io/collector/pdata/ptrace"
)

// Service is one instrumented app and its resource attributes.
type Service struct {
	Name     string
	Resource map[string]any
}

// Scope is an instrumentation scope.
type Scope struct{ Name, Version string }

// Gen produces ids and jitter. A seeded Gen gives the same ids every run.
type Gen struct{ rnd *rand.Rand }

// NewGen returns a deterministic generator for seed.
func NewGen(seed uint64) *Gen {
	var key [32]byte
	binary.LittleEndian.PutUint64(key[:], seed)
	return &Gen{rnd: rand.New(rand.NewChaCha8(key))}
}

// NewRandomGen returns a generator with a random seed.
func NewRandomGen() *Gen { return NewGen(rand.Uint64()) }

// TraceID returns a new non-zero trace id.
func (g *Gen) TraceID() pcommon.TraceID {
	var id pcommon.TraceID
	binary.BigEndian.PutUint64(id[:8], g.rnd.Uint64()|1<<63)
	binary.BigEndian.PutUint64(id[8:], g.rnd.Uint64())
	return id
}

// SpanID returns a new non-zero span id.
func (g *Gen) SpanID() pcommon.SpanID {
	var id pcommon.SpanID
	binary.BigEndian.PutUint64(id[:], g.rnd.Uint64()|1)
	return id
}

// Jitter scales d by a random factor in [1-f, 1+f].
func (g *Gen) Jitter(d time.Duration, f float64) time.Duration {
	return time.Duration(float64(d) * (1 - f + 2*f*g.rnd.Float64()))
}

// IntN returns a random int in [0, n).
func (g *Gen) IntN(n int) int { return g.rnd.IntN(n) }

type scopeKey struct {
	service string
	scope   Scope
}

// Batch collects spans and logs, grouped by resource and scope as an SDK
// exporter would send them.
type Batch struct {
	Traces ptrace.Traces
	Logs   plog.Logs

	spanRes  map[string]ptrace.ResourceSpans
	spanList map[scopeKey]ptrace.SpanSlice
	logRes   map[string]plog.ResourceLogs
	logList  map[scopeKey]plog.LogRecordSlice
}

// NewBatch returns an empty batch.
func NewBatch() *Batch {
	return &Batch{
		Traces:   ptrace.NewTraces(),
		Logs:     plog.NewLogs(),
		spanRes:  map[string]ptrace.ResourceSpans{},
		spanList: map[scopeKey]ptrace.SpanSlice{},
		logRes:   map[string]plog.ResourceLogs{},
		logList:  map[scopeKey]plog.LogRecordSlice{},
	}
}

// SpanCount and LogCount count what the batch holds.
func (b *Batch) SpanCount() int { return b.Traces.SpanCount() }
func (b *Batch) LogCount() int  { return b.Logs.LogRecordCount() }

// NewSpan appends an empty span for svc and scope.
func (b *Batch) NewSpan(svc *Service, sc Scope) ptrace.Span {
	k := scopeKey{svc.Name, sc}
	list, ok := b.spanList[k]
	if !ok {
		rs, ok := b.spanRes[svc.Name]
		if !ok {
			rs = b.Traces.ResourceSpans().AppendEmpty()
			putAll(rs.Resource().Attributes(), svc.Resource)
			b.spanRes[svc.Name] = rs
		}
		ss := rs.ScopeSpans().AppendEmpty()
		ss.Scope().SetName(sc.Name)
		ss.Scope().SetVersion(sc.Version)
		list = ss.Spans()
		b.spanList[k] = list
	}
	return list.AppendEmpty()
}

// NewLog appends an empty log record for svc and scope.
func (b *Batch) NewLog(svc *Service, sc Scope) plog.LogRecord {
	k := scopeKey{svc.Name, sc}
	list, ok := b.logList[k]
	if !ok {
		rl, ok := b.logRes[svc.Name]
		if !ok {
			rl = b.Logs.ResourceLogs().AppendEmpty()
			putAll(rl.Resource().Attributes(), svc.Resource)
			b.logRes[svc.Name] = rl
		}
		sl := rl.ScopeLogs().AppendEmpty()
		sl.Scope().SetName(sc.Name)
		sl.Scope().SetVersion(sc.Version)
		list = sl.LogRecords()
		b.logList[k] = list
	}
	return list.AppendEmpty()
}

// putAll copies Go values into an attribute map.
func putAll(m pcommon.Map, attrs map[string]any) {
	for k, v := range attrs {
		put(m, k, v)
	}
}

func put(m pcommon.Map, k string, v any) {
	switch v := v.(type) {
	case string:
		m.PutStr(k, v)
	case int:
		m.PutInt(k, int64(v))
	case int64:
		m.PutInt(k, v)
	case float64:
		m.PutDouble(k, v)
	case bool:
		m.PutBool(k, v)
	case []string:
		s := m.PutEmptySlice(k)
		for _, e := range v {
			s.AppendEmpty().SetStr(e)
		}
	case map[string]any:
		putAll(m.PutEmptyMap(k), v)
	default:
		panic("sample: unsupported attribute type")
	}
}

// SplitTraces cuts td into requests of at most max spans, keeping resource
// and scope grouping.
func SplitTraces(td ptrace.Traces, max int) []ptrace.Traces {
	if td.SpanCount() <= max {
		return []ptrace.Traces{td}
	}
	var out []ptrace.Traces
	cur, n := ptrace.NewTraces(), 0
	rss := td.ResourceSpans()
	for i := 0; i < rss.Len(); i++ {
		rs := rss.At(i)
		for j := 0; j < rs.ScopeSpans().Len(); j++ {
			ss := rs.ScopeSpans().At(j)
			var dst ptrace.SpanSlice
			open := func() {
				nrs := cur.ResourceSpans().AppendEmpty()
				rs.Resource().CopyTo(nrs.Resource())
				nss := nrs.ScopeSpans().AppendEmpty()
				ss.Scope().CopyTo(nss.Scope())
				dst = nss.Spans()
			}
			open()
			for k := 0; k < ss.Spans().Len(); k++ {
				if n == max {
					out = append(out, cur)
					cur, n = ptrace.NewTraces(), 0
					open()
				}
				ss.Spans().At(k).CopyTo(dst.AppendEmpty())
				n++
			}
		}
	}
	if n > 0 {
		out = append(out, cur)
	}
	return out
}

// Float64 returns a random float in [0, 1).
func (g *Gen) Float64() float64 { return g.rnd.Float64() }
