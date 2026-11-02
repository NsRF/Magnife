package sample

import (
	"testing"
	"time"

	"go.opentelemetry.io/collector/pdata/pcommon"
)

func TestSeedIsDeterministic(t *testing.T) {
	ids := func() []string {
		var out []string
		for _, sc := range Scenarios {
			tr := sc.Add(SeedGen(sc.Name), NewBatch(), time.Unix(0, 0), 1)
			out = append(out, tr.ID.String())
		}
		return out
	}
	a, b := ids(), ids()
	for i := range a {
		if a[i] != b[i] {
			t.Fatalf("scenario %s: %s then %s", Scenarios[i].Name, a[i], b[i])
		}
	}
}

func TestHugeTraceAndSplit(t *testing.T) {
	b, tr := HugeTrace(NewGen(1), 30000, time.Now())
	if b.SpanCount() != 30000 || tr.Spans != 30000 {
		t.Fatalf("spans = %d", b.SpanCount())
	}
	// Depth: follow parents from every span.
	parent := map[pcommon.SpanID]pcommon.SpanID{}
	rss := b.Traces.ResourceSpans()
	for i := 0; i < rss.Len(); i++ {
		for j := 0; j < rss.At(i).ScopeSpans().Len(); j++ {
			ss := rss.At(i).ScopeSpans().At(j).Spans()
			for k := 0; k < ss.Len(); k++ {
				parent[ss.At(k).SpanID()] = ss.At(k).ParentSpanID()
			}
		}
	}
	deepest := 0
	for id := range parent {
		d := 0
		for p := parent[id]; !p.IsEmpty(); p = parent[p] {
			d++
		}
		deepest = max(deepest, d)
	}
	if deepest < 4 {
		t.Fatalf("depth %d, want several levels", deepest)
	}
	parts := SplitTraces(b.Traces, 1000)
	total := 0
	for _, p := range parts {
		if p.SpanCount() > 1000 {
			t.Fatalf("part with %d spans", p.SpanCount())
		}
		total += p.SpanCount()
	}
	if len(parts) != 30 || total != 30000 {
		t.Fatalf("parts=%d total=%d", len(parts), total)
	}
}
