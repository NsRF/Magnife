package main

import (
	"slices"
	"testing"

	"go.opentelemetry.io/collector/pdata/ptrace"

	"magnife/ingest/internal/sample"
)

// volumeRun is what planVolume built: spans, trace ids in order, and root
// spans by name (one per trace: the route or job of its scenario).
type volumeRun struct {
	spans, traces int
	ids           []string
	roots         map[string]int
}

func planned(seed uint64, total int) volumeRun {
	run := volumeRun{roots: map[string]int{}}
	planVolume(sample.NewGen(seed), traceScenarios(sample.Scenarios), total, func(b *sample.Batch, traces int) bool {
		run.spans += b.SpanCount()
		run.traces += traces
		eachSpan(b.Traces, func(s ptrace.Span) {
			if s.ParentSpanID().IsEmpty() {
				run.ids = append(run.ids, s.TraceID().String())
				run.roots[s.Name()]++
			}
		})
		return true
	})
	return run
}

func eachSpan(td ptrace.Traces, f func(ptrace.Span)) {
	rss := td.ResourceSpans()
	for i := 0; i < rss.Len(); i++ {
		sss := rss.At(i).ScopeSpans()
		for j := 0; j < sss.Len(); j++ {
			spans := sss.At(j).Spans()
			for k := 0; k < spans.Len(); k++ {
				f(spans.At(k))
			}
		}
	}
}

// The golden counts of `--volume 12000 --seed N`, measured end to end
// through the helper (seed 1) and by a simulator of the old loop (both).
func TestVolumeSeedGolden(t *testing.T) {
	for _, c := range []struct {
		seed          uint64
		spans, traces int
		roots         map[string]int
	}{
		{1, 12_001, 1_611, map[string]int{
			"GET /checkout": 346, "GET /account/orders": 311, "GET /admin/reports": 315,
			"POST /checkout/pay": 319, "inventory.reconcile": 320,
		}},
		{2, 12_006, 1_624, map[string]int{
			"GET /checkout": 307, "GET /account/orders": 341, "GET /admin/reports": 345,
			"POST /checkout/pay": 302, "inventory.reconcile": 329,
		}},
	} {
		run := planned(c.seed, 12_000)
		if run.spans != c.spans || run.traces != c.traces || len(run.ids) != c.traces {
			t.Errorf("seed %d: %d spans, %d traces (%d roots), want %d and %d", c.seed, run.spans, run.traces, len(run.ids), c.spans, c.traces)
		}
		for name, want := range c.roots {
			if got := run.roots[name]; got != want {
				t.Errorf("seed %d: %d traces of %s, want %d", c.seed, got, name, want)
			}
		}
		if len(run.roots) != len(c.roots) {
			t.Errorf("seed %d: roots %v", c.seed, run.roots)
		}
	}
}

func TestVolumeSeedIsDeterministic(t *testing.T) {
	a, b := planned(1, 12_000), planned(1, 12_000)
	if !slices.Equal(a.ids, b.ids) {
		t.Fatal("seed 1 gave different trace ids on a second run")
	}
	if c := planned(2, 12_000); slices.Equal(a.ids[:10], c.ids[:10]) {
		t.Fatal("seeds 1 and 2 gave the same trace ids")
	}
}

func TestVolumeStopsWhenEmitSaysSo(t *testing.T) {
	batches := 0
	planVolume(sample.NewGen(1), traceScenarios(sample.Scenarios), 12_000, func(*sample.Batch, int) bool {
		batches++
		return batches < 3
	})
	if batches != 3 {
		t.Fatalf("%d batches after emit returned false on the third", batches)
	}
}

func TestPickAcceptsEdgeScenarios(t *testing.T) {
	list, err := pick("healthy, edge-slow-boundary")
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 2 || list[0].Name != "healthy" || list[1].Name != "edge-slow-boundary" {
		t.Fatalf("picked %v", list)
	}
	if _, err := pick("edge-nope"); err == nil {
		t.Fatal("an unknown scenario was accepted")
	}
}
