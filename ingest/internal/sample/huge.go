package sample

import (
	"fmt"
	"time"

	"go.opentelemetry.io/collector/pdata/ptrace"
)

// HugeTrace builds one import job trace with n spans, a tree with up to six
// children per span (five or six levels deep for 30,000 spans).
func HugeTrace(g *Gen, n int, start time.Time) (*Batch, *Trace) {
	const fanout = 6
	b := NewBatch()
	t := &Trace{ID: g.TraceID(), Start: start, Scale: 1, g: g, b: b}
	type node struct {
		span         ptrace.Span
		depth        int
		startMs, dur float64
	}
	total := float64(n) * 2 // ms; children share their parent's time
	root := t.span(nil, CheckoutAPI, scopeAspNetCore, "POST /imports/catalog", ptrace.SpanKindServer, 0, total, map[string]any{
		"http.request.method": "POST", "http.route": "/imports/catalog", "url.path": "/imports/catalog",
		"url.scheme": "http", "http.response.status_code": 202, "import.rows": n,
	})
	queue := []node{{root, 0, 0, total}}
	for len(queue) > 0 && t.Spans < n {
		p := queue[0]
		queue = queue[1:]
		slot := p.dur / fanout
		for i := 0; i < fanout && t.Spans < n; i++ {
			start := p.startMs + float64(i)*slot + slot*0.05
			dur := slot * 0.9
			var s ptrace.Span
			switch d := p.depth + 1; {
			case d == 1:
				s = t.span(&p.span, CheckoutAPI, scopeNetLogs, fmt.Sprintf("ImportChunk %d", i), ptrace.SpanKindInternal, start, dur,
					map[string]any{"import.chunk": i})
			case d%2 == 0:
				s = t.span(&p.span, Orders, scopeOtelSQL, "INSERT products", ptrace.SpanKindClient, start, dur, goSQLAttrs("INSERT", "products",
					"INSERT INTO products (sku, name, price_cents) VALUES ($1, $2, $3) ON CONFLICT (sku) DO UPDATE SET price_cents = excluded.price_cents"))
			default:
				s = t.span(&p.span, CheckoutAPI, scopeNetLogs, "ImportRow", ptrace.SpanKindInternal, start, dur,
					map[string]any{"import.row": t.Spans, "import.depth": d})
			}
			queue = append(queue, node{s, p.depth + 1, start, dur})
		}
	}
	return b, t
}
