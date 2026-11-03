package sample

import (
	"slices"
	"testing"
	"time"

	"go.opentelemetry.io/collector/pdata/pcommon"
	"go.opentelemetry.io/collector/pdata/ptrace"
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

// spansOf lists a batch's spans.
func spansOf(b *Batch) []ptrace.Span {
	var out []ptrace.Span
	rss := b.Traces.ResourceSpans()
	for i := 0; i < rss.Len(); i++ {
		sss := rss.At(i).ScopeSpans()
		for j := 0; j < sss.Len(); j++ {
			spans := sss.At(j).Spans()
			for k := 0; k < spans.Len(); k++ {
				out = append(out, spans.At(k))
			}
		}
	}
	return out
}

// The seed set the snapshots and the self-test count on: 5 traces, 37
// spans and 20 logs, with these ids. The edge set must not change it.
func TestSeedSetUnchanged(t *testing.T) {
	want := []struct {
		name        string
		spans, logs int
		id          string
	}{
		{"logs", 0, 8, ""},
		{"healthy", 12, 4, "ba9dbcd0dd475eeb52ae0eb22ff9defd"},
		{"n-plus-one", 14, 1, "e1cc591c804ffeeeca29b13ca4032264"},
		{"slow-query", 4, 1, "ac389f1bbef04de031f7b4ca12ee833c"},
		{"http-500", 5, 5, "bc5b77bdd1f8b46622194f4aea57eaac"},
		{"exception", 2, 1, "ef764bd47215bf1f018d0c1c98d9be99"},
	}
	if len(Scenarios) != len(want) {
		t.Fatalf("%d seed scenarios, want %d", len(Scenarios), len(want))
	}
	spans, logs := 0, 0
	for i, sc := range Scenarios {
		w := want[i]
		b := NewBatch()
		tr := sc.Add(SeedGen(sc.Name), b, time.Unix(1_700_000_000, 0), 1)
		if sc.Name != w.name || tr.Spans != w.spans || tr.Logs != w.logs || b.SpanCount() != w.spans || b.LogCount() != w.logs {
			t.Errorf("scenario %d %s: %d spans, %d logs, want %s with %d and %d", i, sc.Name, tr.Spans, tr.Logs, w.name, w.spans, w.logs)
		}
		if w.id != "" && tr.ID.String() != w.id {
			t.Errorf("%s: trace %s, want %s", sc.Name, tr.ID, w.id)
		}
		spans += tr.Spans
		logs += tr.Logs
	}
	if spans != 37 || logs != 20 {
		t.Errorf("seed set: %d spans, %d logs, want 37 and 20", spans, logs)
	}
	for _, sc := range EdgeScenarios {
		if _, ok := Lookup(sc.Name); ok {
			t.Errorf("edge scenario %s is in the seed set", sc.Name)
		}
	}
}

func TestEdgeSetIsDeterministic(t *testing.T) {
	want := []struct {
		name  string
		spans int
		id    string
	}{
		{"edge-slow-boundary", 8, "c777f2805d6c14cc9d377baf2e8ece72"},
		{"edge-n-plus-one-parents", 20, "8cb5882e0d71db79007aea27436f3254"},
		{"edge-n-plus-one-services", 11, "bcd4b7d52fe651de1d7d4d682593f5c1"},
		{"edge-http-4xx", 7, "cc0268a869e5712fcb5dfe2e6e69ad58"},
		{"edge-http-no-code", 2, "ae8074db3760c149a7e1bc94b741759c"},
		{"edge-http-old-conventions", 3, "a9c307e5e0919f46aebbafb03cfa42c6"},
	}
	if len(EdgeScenarios) != len(want) {
		t.Fatalf("%d edge scenarios, want %d", len(EdgeScenarios), len(want))
	}
	spanIDs := func(sc Scenario) (string, []string) {
		b := NewBatch()
		tr := sc.Add(SeedGen(sc.Name), b, time.Unix(1_700_000_000, 0), 1)
		var ids []string
		for _, s := range spansOf(b) {
			ids = append(ids, s.SpanID().String())
			if s.TraceID() != tr.ID {
				t.Errorf("%s: span %s in trace %s", sc.Name, s.Name(), s.TraceID())
			}
		}
		return tr.ID.String(), ids
	}
	total := 0
	for i, sc := range EdgeScenarios {
		w := want[i]
		id, ids := spanIDs(sc)
		again, idsAgain := spanIDs(sc)
		if sc.Name != w.name || id != w.id || len(ids) != w.spans {
			t.Errorf("edge %d %s: trace %s with %d spans, want %s: %s with %d", i, sc.Name, id, len(ids), w.name, w.id, w.spans)
		}
		if again != id || !slices.Equal(ids, idsAgain) {
			t.Errorf("%s: ids differ between two runs", sc.Name)
		}
		if found, ok := LookupEdge(sc.Name); !ok || found.Name != sc.Name {
			t.Errorf("LookupEdge(%q) failed", sc.Name)
		}
		total += len(ids)
	}
	if total != 51 {
		t.Errorf("edge set: %d spans, want 51", total)
	}
}

// The Slow SQL threshold edges keep their exact nanoseconds.
func TestEdgeBoundaries(t *testing.T) {
	sc, _ := LookupEdge("edge-slow-boundary")
	b := NewBatch()
	sc.Add(SeedGen(sc.Name), b, time.Unix(1_700_000_000, 123_456_789), 1)
	want := map[string]int64{
		"SELECT DailyTotals": 99_900_000, "SELECT WeeklyTotals": 100_000_000,
		"SELECT MonthlyTotals": 100_400_000, "SELECT YearlyTotals": 101_000_000,
		"SELECT Ledger": 330_000_000,
	}
	seen := 0
	for _, s := range spansOf(b) {
		w, ok := want[s.Name()]
		if !ok {
			continue
		}
		seen++
		if got := int64(s.EndTimestamp() - s.StartTimestamp()); got != w {
			t.Errorf("%s: %d ns, want %d", s.Name(), got, w)
		}
		text, ok := s.Attributes().Get("db.query.text")
		if !ok {
			t.Errorf("%s: no db.query.text", s.Name())
			continue
		}
		if s.Name() == "SELECT Ledger" && text.Str() != "" {
			t.Errorf("SELECT Ledger: db.query.text %q, want empty", text.Str())
		}
		if s.Name() != "SELECT Ledger" && text.Str() == "" {
			t.Errorf("%s: empty db.query.text", s.Name())
		}
	}
	if seen != len(want) {
		t.Errorf("%d of %d database spans found", seen, len(want))
	}
}
