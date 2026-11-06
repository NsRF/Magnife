package sample

import (
	"fmt"

	"go.opentelemetry.io/collector/pdata/ptrace"
)

// CompareScenarios are two traces of one route, a fast one and a slow one,
// for comparing traces (S-036). Like the edge set they are not part of
// Scenarios: send-sample-traces --compare sends them, fast first, with
// fixed ids (SeedGen) and scale 1. Between them, the slow one has a 300 ms
// slower SELECT orders, 8 order_items runs instead of 2, a new inventory
// call, no cache lookup, and a recommendations call that fails.
var CompareScenarios = []Scenario{
	{"compare-orders-fast", "GET /account/orders in 64 ms: a cache hit, 2 order_items runs", compareFast},
	{"compare-orders-slow", "GET /account/orders in 420 ms: a 320 ms SELECT orders, 8 order_items runs, an inventory call, a 503", compareSlow},
}

// LookupCompare finds a compare scenario by name.
func LookupCompare(name string) (Scenario, bool) {
	for _, s := range CompareScenarios {
		if s.Name == name {
			return s, true
		}
	}
	return Scenario{}, false
}

var scopeRedis = Scope{"OpenTelemetry.Instrumentation.StackExchangeRedis", "1.12.0-beta.2"}

// compareTimes are the milliseconds that differ between the two traces.
type compareTimes struct {
	total, orders, selectOrders, itemsAt float64
	items                                int
}

// compareCall is the request both traces share: web -> checkout-api ->
// orders, in the times given.
func compareCall(t *Trace, c compareTimes) (api, srv ptrace.Span) {
	web := t.span(nil, Web, scopeNodeHTTP, "GET /account/orders", ptrace.SpanKindServer, 0, c.total, map[string]any{
		"http.request.method": "GET", "http.route": "/account/orders", "url.path": "/account/orders",
		"url.scheme": "http", "server.address": "localhost", "server.port": 3000, "http.response.status_code": 200,
	})
	call := t.span(&web, Web, scopeNodeUndici, "GET", ptrace.SpanKindClient, 2, c.total-4, map[string]any{
		"http.request.method": "GET", "url.full": "http://localhost:5080/orders/history?customerId=77",
		"server.address": "localhost", "server.port": 5080, "http.response.status_code": 200,
	})
	api = t.span(&call, CheckoutAPI, scopeAspNetCore, "GET /orders/history", ptrace.SpanKindServer, 4, c.total-8, map[string]any{
		"http.request.method": "GET", "http.route": "/orders/history", "url.path": "/orders/history",
		"url.query": "customerId=77", "url.scheme": "http", "http.response.status_code": 200,
	})
	out := t.span(&api, CheckoutAPI, scopeHTTPClient, "GET", ptrace.SpanKindClient, 8, c.orders+4, map[string]any{
		"http.request.method": "GET", "url.full": "http://localhost:8081/v1/orders?customer_id=77",
		"server.address": "localhost", "server.port": 8081, "http.response.status_code": 200,
	})
	srv = t.span(&out, Orders, scopeOtelHTTP, "GET /v1/orders", ptrace.SpanKindServer, 10, c.orders, map[string]any{
		"http.method": "GET", "http.route": "/v1/orders", "http.target": "/v1/orders?customer_id=77",
		"http.scheme": "http", "http.status_code": 200, "net.host.name": "localhost", "net.host.port": 8081,
	})
	t.span(&srv, Orders, scopeOtelSQL, "SELECT orders", ptrace.SpanKindClient, 12, c.selectOrders, goSQLAttrs("SELECT", "orders",
		"SELECT id, status, total_cents, created_at FROM orders WHERE customer_id = 77 ORDER BY created_at DESC LIMIT 8"))
	for i := range c.items {
		t.span(&srv, Orders, scopeOtelSQL, "SELECT order_items", ptrace.SpanKindClient, c.itemsAt+float64(i)*6, 5, goSQLAttrs("SELECT", "order_items",
			fmt.Sprintf("SELECT * FROM order_items WHERE order_id = %d", 1042+i)))
	}
	return api, srv
}

func recommendations(t *Trace, api *ptrace.Span, at, dur float64, code int) ptrace.Span {
	s := t.span(api, CheckoutAPI, scopeHTTPClient, "GET", ptrace.SpanKindClient, at, dur, map[string]any{
		"http.request.method": "GET", "url.full": "http://localhost:8083/v1/recommendations?customer_id=77",
		"server.address": "localhost", "server.port": 8083, "http.response.status_code": code,
	})
	return s
}

func compareFast(t *Trace) {
	api, _ := compareCall(t, compareTimes{total: 64, orders: 40, selectOrders: 20, itemsAt: 34, items: 2})
	t.span(&api, CheckoutAPI, scopeRedis, "HGET", ptrace.SpanKindClient, 5, 1, map[string]any{
		"db.system": "redis", "db.statement": "HGET order-history:77 summary", "server.address": "localhost", "server.port": 6379,
	})
	recommendations(t, &api, 54, 4, 200)
}

func compareSlow(t *Trace) {
	api, srv := compareCall(t, compareTimes{total: 420, orders: 392, selectOrders: 320, itemsAt: 334, items: 8})
	t.span(&srv, Orders, scopeOtelHTTP, "GET", ptrace.SpanKindClient, 382, 18, map[string]any{
		"http.request.method": "GET", "url.full": "http://localhost:8082/v1/inventory?order_ids=1042,1043,1044,1045,1046,1047,1048,1049",
		"server.address": "localhost", "server.port": 8082, "http.response.status_code": 200,
	})
	rec := recommendations(t, &api, 408, 6, 503)
	setError(rec, "503 Service Unavailable")
}
