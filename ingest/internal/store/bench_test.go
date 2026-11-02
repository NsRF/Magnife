package store_test

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"magnife/ingest/internal/convert"
	"magnife/ingest/internal/sample"
	"magnife/ingest/internal/store"
)

// BenchmarkCommit measures committing realistic batches of about 2,000 records.
func BenchmarkCommit(b *testing.B) {
	dir, _ := os.MkdirTemp("/tmp", "magnife-bench-")
	defer os.RemoveAll(dir)
	st, err := store.Open(filepath.Join(dir, "m.sqlite"))
	if err != nil {
		b.Fatal(err)
	}
	defer st.Close()
	g := sample.NewGen(7)
	var batches [][]*store.Batch
	for range 20 {
		sb := sample.NewBatch()
		for sb.SpanCount() < 1500 {
			sc := sample.Scenarios[1+g.IntN(len(sample.Scenarios)-1)]
			sc.Add(g, sb, time.Now(), 1)
		}
		spans, _ := convert.Traces(sb.Traces)
		batches = append(batches, []*store.Batch{{Spans: spans, Logs: convert.Logs(sb.Logs)}})
	}
	b.ResetTimer()
	spans := 0
	for i := 0; b.Loop(); i++ {
		bt := batches[i%len(batches)]
		if i >= len(batches) {
			// Fresh ids each round so every span is an insert, as in real traffic.
			b.StopTimer()
			sb := sample.NewBatch()
			for sb.SpanCount() < 1500 {
				sample.Scenarios[1+g.IntN(len(sample.Scenarios)-1)].Add(g, sb, time.Now(), 1)
			}
			s, _ := convert.Traces(sb.Traces)
			bt = []*store.Batch{{Spans: s, Logs: convert.Logs(sb.Logs)}}
			b.StartTimer()
		}
		if _, err := st.Commit(bt); err != nil {
			b.Fatal(err)
		}
		spans += len(bt[0].Spans)
	}
	b.ReportMetric(float64(spans)/b.Elapsed().Seconds(), "spans/s")
}
