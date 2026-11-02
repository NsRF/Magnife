// Command send-sample-traces sends realistic OTLP traces and logs from three
// services (checkout-api, orders, web) to a Magnife helper or any collector.
//
// With no mode flag it sends the deterministic seed set used for app
// snapshots: one trace per scenario, fixed ids, timestamps relative to now.
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
	scenarios := flag.String("scenarios", "", "comma-separated scenarios (default: all of "+names()+")")
	volume := flag.Int("volume", 0, "send random traces of the scenarios until `N` spans are sent")
	huge := flag.Int("huge-trace", 0, "send one trace with `N` spans, nested several levels deep")
	rate := flag.Int("rate", 0, "send `spans/s` of random traces for --duration")
	duration := seconds(60 * time.Second)
	flag.Var(&duration, "duration", "how long --rate runs, in `seconds` (60) or as a duration (90s, 2m)")
	live := flag.Bool("live", false, "send a random trace every 1-2 s until interrupted")
	workers := flag.Int("workers", 8, "concurrent requests in --volume, --rate and --huge-trace")
	flag.Parse()

	fail := func(msg string) {
		fmt.Fprintf(os.Stderr, "send-sample-traces: %s\n", msg)
		os.Exit(2)
	}
	modes := 0
	for _, on := range []bool{*volume > 0, *huge > 0, *rate > 0, *live} {
		if on {
			modes++
		}
	}
	if modes > 1 {
		fail("use only one of --volume, --huge-trace, --rate and --live")
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

	switch {
	case *volume > 0:
		mode = fmt.Sprintf("volume %d", *volume)
		runVolume(ctx, s, list, *volume, *workers)
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
		runRate(ctx, s, list, *rate, time.Duration(duration), *workers)
	case *live:
		mode = "live"
		runLive(ctx, s, list)
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

func names() string {
	var n []string
	for _, s := range sample.Scenarios {
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
			return nil, fmt.Errorf("unknown scenario %q (known: %s)", name, names())
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

// fill adds random traces to a new batch until it has about want spans.
func fill(g *sample.Gen, list []sample.Scenario, want int, st *stats) *sample.Batch {
	b := sample.NewBatch()
	now := time.Now()
	for b.SpanCount() < want {
		sc := list[g.IntN(len(list))]
		start := now.Add(-time.Duration(g.IntN(60_000)) * time.Millisecond)
		t := sc.Add(g, b, start, 0.6+0.8*g.Float64())
		if t.Spans == 0 && b.LogCount() > want {
			break
		}
		if t.Spans > 0 {
			st.traces.Add(1)
		}
	}
	return b
}

func runVolume(ctx context.Context, s *sender, list []sample.Scenario, total, workers int) {
	g := sample.NewRandomGen()
	list = traceScenarios(list)
	jobs, wait := s.pool(ctx, workers)
	for queued := 0; queued < total && ctx.Err() == nil; {
		b := fill(g, list, min(spansPerRequest, total-queued), s.st)
		queued += max(1, b.SpanCount())
		jobs <- b
	}
	wait()
}

func runRate(ctx context.Context, s *sender, list []sample.Scenario, rate int, d time.Duration, workers int) {
	g := sample.NewRandomGen()
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
				b := fill(g, list, min(spansPerRequest, due-queued), s.st)
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

func runLive(ctx context.Context, s *sender, list []sample.Scenario) {
	g := sample.NewRandomGen()
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
