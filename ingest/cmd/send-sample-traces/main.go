// Command send-sample-traces sends realistic OTLP traces and logs from three
// services (checkout-api, orders, web) to a Magnife helper or any collector.
//
// With no mode flag it sends the deterministic seed set used for app
// snapshots: one trace per scenario, fixed ids, timestamps relative to now.
// --edges sends the detector edge set the same way, and --compare the compare
// set (S-036). --seed makes --volume,
// --rate and --live send the same traces (ids, scenarios, scales) every run.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"magnife/ingest/internal/sample"
)

// Spans per request, about what an SDK's batch processor sends.
const spansPerRequest = 512

type stats struct {
	spans, logs, traces, requests, errors atomic.Int64
}

func (s *stats) fail(err error) {
	if s.errors.Add(1) <= 5 {
		fmt.Fprintf(os.Stderr, "send-sample-traces: %v\n", err)
	}
}

type sender struct {
	exp exporter
	st  *stats
}

// send exports the batch's spans (in chunks of at most 1,000) and its logs.
func (s *sender) send(ctx context.Context, b *sample.Batch) {
	if b.SpanCount() > 0 {
		for _, td := range sample.SplitTraces(b.Traces, 1000) {
			s.st.requests.Add(1)
			if err := s.exp.Traces(ctx, td); err != nil {
				s.st.fail(err)
				continue
			}
			s.st.spans.Add(int64(td.SpanCount()))
		}
	}
	if b.LogCount() > 0 {
		s.st.requests.Add(1)
		if err := s.exp.Logs(ctx, b.Logs); err != nil {
			s.st.fail(err)
			return
		}
		s.st.logs.Add(int64(b.LogCount()))
	}
}

// pool runs send on several goroutines, as several app instances would.
func (s *sender) pool(ctx context.Context, workers int) (chan<- *sample.Batch, func()) {
	jobs := make(chan *sample.Batch, workers*2)
	var wg sync.WaitGroup
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for b := range jobs {
				s.send(ctx, b)
			}
		}()
	}
	return jobs, func() { close(jobs); wg.Wait() }
}

func main() {
	httpAddr := flag.String("http", "127.0.0.1:4318", "OTLP/HTTP `host:port`")
	grpcAddr := flag.String("grpc", "127.0.0.1:4317", "OTLP/gRPC `host:port`")
	protocol := flag.String("protocol", "mixed", "http-protobuf, http-json, grpc, or mixed (rotates through all three, with and without gzip)")
	compression := flag.String("compression", "gzip", "gzip or none (ignored by --protocol mixed)")
	scenarios := flag.String("scenarios", "", "comma-separated scenarios (default: all of "+names()+"; edge scenarios: "+edgeNames()+")")
	volume := flag.Int("volume", 0, "send random traces of the scenarios until `N` spans are sent")
	huge := flag.Int("huge-trace", 0, "send one trace with `N` spans, nested several levels deep")
	rate := flag.Int("rate", 0, "send `spans/s` of random traces for --duration")
	duration := seconds(60 * time.Second)
	flag.Var(&duration, "duration", "how long --rate runs, in `seconds` (60) or as a duration (90s, 2m)")
	live := flag.Bool("live", false, "send a random trace every 1-2 s until interrupted")
	edges := flag.Bool("edges", false, "send the detector edge set (one trace per edge scenario, fixed ids) instead of the seed set")
	compare := flag.Bool("compare", false, "send the compare set (a fast and a slow GET /account/orders, fixed ids) instead of the seed set")
	seed := flag.Uint64("seed", 0, "seed for --volume, --rate and --live, so each run sends the same traces (0: a random seed each run)")
	workers := flag.Int("workers", 8, "concurrent requests in --volume, --rate and --huge-trace")
	flag.Parse()

	fail := func(msg string) {
		fmt.Fprintf(os.Stderr, "send-sample-traces: %s\n", msg)
		os.Exit(2)
	}
	modes := 0
	for _, on := range []bool{*volume > 0, *huge > 0, *rate > 0, *live, *edges, *compare} {
		if on {
			modes++
		}
	}
	if modes > 1 {
		fail("use only one of --volume, --huge-trace, --rate, --live, --edges and --compare")
	}
	list, err := pick(*scenarios)
	if err != nil {
		fail(err.Error())
	}
	if *compression != "gzip" && *compression != "none" {
		fail("--compression must be gzip or none")
	}
	exp, err := newExporter(*protocol, *httpAddr, *grpcAddr, *compression == "gzip")
	if err != nil {
		fail(err.Error())
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	st := &stats{}
	s := &sender{exp: exp, st: st}
	began := time.Now()
	mode := "seed set"
	newGen := func() *sample.Gen {
		if *seed != 0 {
			return sample.NewGen(*seed)
		}
		return sample.NewRandomGen()
	}

	switch {
	case *edges:
		mode = "edge set"
		if *scenarios == "" {
			list = sample.EdgeScenarios
		}
		runSeed(ctx, s, list)
	case *compare:
		mode = "compare set"
		if *scenarios == "" {
			list = sample.CompareScenarios
		}
		runSeed(ctx, s, list)
	case *volume > 0:
		mode = fmt.Sprintf("volume %d", *volume)
		runVolume(ctx, s, newGen(), list, *volume, *workers)
	case *huge > 0:
		mode = fmt.Sprintf("huge trace of %d spans", *huge)
		b, t := sample.HugeTrace(sample.NewRandomGen(), *huge, time.Now().Add(-time.Duration(*huge)*2*time.Millisecond))
		jobs, wait := s.pool(ctx, *workers)
		for _, td := range sample.SplitTraces(b.Traces, 1000) {
			part := sample.NewBatch()
			part.Traces = td
			jobs <- part
		}
		wait()
		st.traces.Add(1)
		fmt.Fprintf(os.Stderr, "send-sample-traces: trace %s\n", t.ID)
	case *rate > 0:
		mode = fmt.Sprintf("%d spans/s for %s", *rate, time.Duration(duration))
		runRate(ctx, s, newGen(), list, *rate, time.Duration(duration), *workers)
	case *live:
		mode = "live"
		runLive(ctx, s, newGen(), list)
	default:
		runSeed(ctx, s, list)
	}

	elapsed := time.Since(began)
	fmt.Fprintf(os.Stderr, "send-sample-traces: %s over %s to http %s / grpc %s: %d spans in %d traces, %d logs, %d requests, %d errors in %.2fs (%.0f spans/s)\n",
		mode, exp.Name(), *httpAddr, *grpcAddr, st.spans.Load(), st.traces.Load(), st.logs.Load(), st.requests.Load(),
		st.errors.Load(), elapsed.Seconds(), float64(st.spans.Load())/elapsed.Seconds())
	if st.errors.Load() > 0 {
		os.Exit(1)
	}
}

// seconds is a duration flag that also takes a plain number of seconds.
type seconds time.Duration

func (s *seconds) String() string { return time.Duration(*s).String() }

func (s *seconds) Set(v string) error {
	if n, err := strconv.ParseFloat(v, 64); err == nil {
		*s = seconds(n * float64(time.Second))
		return nil
	}
	d, err := time.ParseDuration(v)
	*s = seconds(d)
	return err
}

func names() string { return join(sample.Scenarios) }

func edgeNames() string { return join(sample.EdgeScenarios) }

func join(list []sample.Scenario) string {
	var n []string
	for _, s := range list {
		n = append(n, s.Name)
	}
	return strings.Join(n, ",")
}

func pick(flagValue string) ([]sample.Scenario, error) {
	if flagValue == "" {
		return sample.Scenarios, nil
	}
	var out []sample.Scenario
	for _, name := range strings.Split(flagValue, ",") {
		sc, ok := sample.Lookup(strings.TrimSpace(name))
		if !ok {
			sc, ok = sample.LookupEdge(strings.TrimSpace(name))
		}
		if !ok {
			sc, ok = sample.LookupCompare(strings.TrimSpace(name))
		}
		if !ok {
			return nil, fmt.Errorf("unknown scenario %q (known: %s; edge scenarios: %s; compare scenarios: %s)", name, names(), edgeNames(), join(sample.CompareScenarios))
		}
		out = append(out, sc)
	}
	return out, nil
}

// runSeed sends one trace per scenario, in order, with fixed ids and start
// times spread over the last few minutes. Resending replaces the same spans.
func runSeed(ctx context.Context, s *sender, list []sample.Scenario) {
	now := time.Now()
	for i, sc := range list {
		b := sample.NewBatch()
		start := now.Add(-time.Duration(len(list)-i) * 30 * time.Second)
		t := sc.Add(sample.SeedGen(sc.Name), b, start, 1)
		s.send(ctx, b)
		if t.Spans > 0 {
			s.st.traces.Add(1)
			fmt.Fprintf(os.Stderr, "send-sample-traces: %-10s trace %s (%d spans, %d logs)\n", sc.Name, t.ID, t.Spans, t.Logs)
		} else {
			fmt.Fprintf(os.Stderr, "send-sample-traces: %-10s %d logs without a trace\n", sc.Name, t.Logs)
		}
	}
}

// traceScenarios drops the logs-only scenario from random modes unless it is
// all there is.
func traceScenarios(list []sample.Scenario) []sample.Scenario {
	out := slices.DeleteFunc(slices.Clone(list), func(s sample.Scenario) bool { return s.Name == "logs" })
	if len(out) == 0 {
		return list
	}
	return out
}

// fill adds random traces to a new batch until it has about want spans,
// and says how many traces it added. The draws per trace, in order: the
// scenario, the start, the scale, then the scenario's own.
func fill(g *sample.Gen, list []sample.Scenario, want int) (*sample.Batch, int) {
	b := sample.NewBatch()
	traces := 0
	now := time.Now()
	for b.SpanCount() < want {
		sc := list[g.IntN(len(list))]
		start := now.Add(-time.Duration(g.IntN(60_000)) * time.Millisecond)
		t := sc.Add(g, b, start, 0.6+0.8*g.Float64())
		if t.Spans == 0 && b.LogCount() > want {
			break
		}
		if t.Spans > 0 {
			traces++
		}
	}
	return b, traces
}

// planVolume builds the batches of a --volume run of total spans, in order,
// on the caller's goroutine, so a seeded g gives the same batches every run.
// emit gets each batch with the number of traces in it, and returns false
// to stop.
func planVolume(g *sample.Gen, list []sample.Scenario, total int, emit func(b *sample.Batch, traces int) bool) {
	for queued := 0; queued < total; {
		b, traces := fill(g, list, min(spansPerRequest, total-queued))
		queued += max(1, b.SpanCount())
		if !emit(b, traces) {
			return
		}
	}
}

// runVolume generates the batches on one goroutine; the workers only send.
func runVolume(ctx context.Context, s *sender, g *sample.Gen, list []sample.Scenario, total, workers int) {
	list = traceScenarios(list)
	jobs, wait := s.pool(ctx, workers)
	defer wait()
	planVolume(g, list, total, func(b *sample.Batch, traces int) bool {
		if ctx.Err() != nil {
			return false
		}
		s.st.traces.Add(int64(traces))
		jobs <- b
		return true
	})
}

func runRate(ctx context.Context, s *sender, g *sample.Gen, list []sample.Scenario, rate int, d time.Duration, workers int) {
	list = traceScenarios(list)
	jobs, wait := s.pool(ctx, workers)
	defer wait()
	began := time.Now()
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	queued := 0
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-tick.C:
			elapsed := min(now.Sub(began), d)
			due := int(float64(rate) * elapsed.Seconds())
			for queued < due {
				b, traces := fill(g, list, min(spansPerRequest, due-queued))
				s.st.traces.Add(int64(traces))
				queued += max(1, b.SpanCount())
				select {
				case jobs <- b:
				case <-ctx.Done():
					return
				}
			}
			if elapsed >= d {
				return
			}
		}
	}
}

func runLive(ctx context.Context, s *sender, g *sample.Gen, list []sample.Scenario) {
	list = traceScenarios(list)
	for {
		sc := list[g.IntN(len(list))]
		b := sample.NewBatch()
		t := sc.Add(g, b, time.Now(), 0.6+0.8*g.Float64())
		s.send(ctx, b)
		if t.Spans > 0 {
			s.st.traces.Add(1)
		}
		fmt.Fprintf(os.Stderr, "send-sample-traces: %-10s trace %s (%d spans, %d logs)\n", sc.Name, t.ID, t.Spans, t.Logs)
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Second + time.Duration(g.IntN(1000))*time.Millisecond):
		}
	}
}
