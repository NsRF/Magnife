package sample

import (
	"fmt"
	"time"

	"go.opentelemetry.io/collector/pdata/pcommon"
	"go.opentelemetry.io/collector/pdata/ptrace"
)

// EdgeScenarios exercise the detectors' boundaries (S-023 to S-025). They
// are not part of Scenarios: the seed set, --volume, --rate and --live
// never send them, so the seed set's counts and the volume mix stay as
// they are. send-sample-traces --edges sends them, one trace each, with
// fixed ids (SeedGen) and exact nanosecond durations (scale is always 1).
var EdgeScenarios = []Scenario{
	{"edge-slow-boundary", "database spans at 99.9, 100.0, 100.4, 101 and 330 ms (one without a statement)", edgeSlowBoundary},
	{"edge-n-plus-one-parents", "one statement 6 times under two handlers, an IN list 5 times with sqlcommenter comments, a 4-time near miss", edgeNPlusOneParents},
	{"edge-n-plus-one-services", "one statement 3 times in checkout-api and 3 times in orders, one run also slow", edgeNPlusOneServices},
	{"edge-http-4xx", "404 and 400 on both client and server spans, 304s not flagged", edgeHTTP4xx},
	{"edge-http-no-code", "a 502 server span over a client call with status Error and no response code", edgeHTTPNoCode},
	{"edge-http-old-conventions", "a 200 with status Error over a 503 client call to an orders server span in the old conventions", edgeHTTPOldConventions},
}

// LookupEdge finds an edge scenario by name.
func LookupEdge(name string) (Scenario, bool) {
	for _, s := range EdgeScenarios {
		if s.Name == name {
			return s, true
		}
	}
	return Scenario{}, false
}

const msNs = int64(time.Millisecond)

// spanNs adds a span with exact start and duration in nanoseconds from
// Start, ignoring Scale: the threshold edges must not be rounded.
func (t *Trace) spanNs(parent *ptrace.Span, svc *Service, sc Scope, name string, kind ptrace.SpanKind,
	startNs, durNs int64, attrs map[string]any) ptrace.Span {
	s := t.span(parent, svc, sc, name, kind, 0, 0, attrs)
	base := t.Start.UnixNano()
	s.SetStartTimestamp(pcommon.Timestamp(base + startNs))
	s.SetEndTimestamp(pcommon.Timestamp(base + startNs + durNs))
	return s
}

func ms(v float64) int64 { return int64(v*1000+0.5) * int64(time.Microsecond) }

func serverAttrs(method, route, path string, code int) map[string]any {
	return map[string]any{
		"http.request.method": method, "http.route": route, "url.path": path, "url.scheme": "http",
		"http.response.status_code": code,
	}
}

func clientAttrs(method, url string, code int) map[string]any {
	a := map[string]any{"http.request.method": method, "url.full": url}
	if code != 0 {
		a["http.response.status_code"] = code
	}
	return a
}

func edgeSlowBoundary(t *Trace) {
	web := t.spanNs(nil, Web, scopeNodeHTTP, "GET /edge/slow", ptrace.SpanKindServer, 0, ms(800),
		serverAttrs("GET", "/edge/slow", "/edge/slow", 200))
	call := t.spanNs(&web, Web, scopeNodeUndici, "GET", ptrace.SpanKindClient, ms(2), ms(796),
		clientAttrs("GET", "http://localhost:5080/reports/thresholds", 200))
	api := t.spanNs(&call, CheckoutAPI, scopeAspNetCore, "GET /reports/thresholds", ptrace.SpanKindServer, ms(4), ms(792),
		serverAttrs("GET", "/reports/thresholds", "/reports/thresholds", 200))
	for _, q := range []struct {
		name, table, col string
		start, dur       int64
	}{
		{"SELECT DailyTotals", "DailyTotals", "Day", ms(10), ms(99.9)},
		{"SELECT WeeklyTotals", "WeeklyTotals", "Week", ms(120), ms(100)},
		{"SELECT MonthlyTotals", "MonthlyTotals", "Month", ms(230), ms(100.4)},
		{"SELECT YearlyTotals", "YearlyTotals", "Year", ms(340), ms(101)},
	} {
		t.spanNs(&api, CheckoutAPI, scopeEFCore, q.name, ptrace.SpanKindClient, q.start, q.dur, efAttrs("SELECT", q.table,
			fmt.Sprintf(`SELECT "%s", "Total" FROM "%s" WHERE "%s" >= @__since_0`, q.col, q.table, q.col)))
	}
	// No statement: db.query.text is empty, so db_statement is NULL.
	t.spanNs(&api, CheckoutAPI, scopeEFCore, "SELECT Ledger", ptrace.SpanKindClient, ms(450), ms(330), efAttrs("SELECT", "Ledger", ""))
}

func edgeNPlusOneParents(t *Trace) {
	web := t.spanNs(nil, Web, scopeNodeHTTP, "GET /edge/dashboard", ptrace.SpanKindServer, 0, ms(120),
		serverAttrs("GET", "/edge/dashboard", "/edge/dashboard", 200))
	call := t.spanNs(&web, Web, scopeNodeUndici, "GET", ptrace.SpanKindClient, ms(2), ms(116),
		clientAttrs("GET", "http://localhost:5080/dashboard?customerId=17", 200))
	api := t.spanNs(&call, CheckoutAPI, scopeAspNetCore, "GET /dashboard", ptrace.SpanKindServer, ms(4), ms(112),
		serverAttrs("GET", "/dashboard", "/dashboard", 200))
	recent := t.spanNs(&api, CheckoutAPI, scopeNetLogs, "LoadRecentOrders", ptrace.SpanKindInternal, ms(6), ms(50), nil)
	carts := t.spanNs(&api, CheckoutAPI, scopeNetLogs, "LoadOpenCarts", ptrace.SpanKindInternal, ms(60), ms(54), nil)
	customer := func(parent *ptrace.Span, id int, start, dur float64) {
		t.spanNs(parent, CheckoutAPI, scopeEFCore, "SELECT Customers", ptrace.SpanKindClient, ms(start), ms(dur),
			efAttrs("SELECT", "Customers", fmt.Sprintf(`SELECT "Name", "Email" FROM "Customers" WHERE "Id" = %d`, id)))
	}
	customer(&recent, 17, 8, 3.1)
	customer(&recent, 18, 13, 5.0)
	customer(&recent, 19, 20, 9.8)
	skus := []string{"'SKU-1'", "'SKU-1', 'SKU-2'", "'SKU-1', 'SKU-2', 'SKU-3'", "'SKU-1', 'SKU-2', 'SKU-3', 'SKU-4'",
		"'SKU-1', 'SKU-2', 'SKU-3', 'SKU-4', 'SKU-5'"}
	for i, list := range skus {
		// sqlcommenter: a different traceparent comment on every run.
		stmt := fmt.Sprintf("/*traceparent='00-%s-%016x-01'*/ SELECT sku, price_cents FROM prices WHERE sku IN (%s)", t.ID, i+1, list)
		t.spanNs(&recent, CheckoutAPI, scopeEFCore, "SELECT prices", ptrace.SpanKindClient, ms(31+3*float64(i)), ms(2),
			efAttrs("SELECT", "prices", stmt))
	}
	customer(&carts, 20, 62, 4.0)
	customer(&carts, 21, 67, 6.0)
	customer(&carts, 22, 74, 7.0)
	for i := range 4 { // 4 times: one short of N+1
		t.spanNs(&carts, CheckoutAPI, scopeEFCore, "SELECT Carts", ptrace.SpanKindClient, ms(82+4*float64(i)), ms(2.5),
			efAttrs("SELECT", "Carts", fmt.Sprintf(`SELECT c."Id", c."Total" FROM "Carts" AS c WHERE c."CustomerId" = %d`, 17+i)))
	}
}

func edgeNPlusOneServices(t *Trace) {
	const stmt = "SELECT available FROM inventory WHERE sku = 'SKU-1042'"
	web := t.spanNs(nil, Web, scopeNodeHTTP, "GET /edge/stock", ptrace.SpanKindServer, 0, ms(200),
		serverAttrs("GET", "/edge/stock", "/edge/stock", 200))
	call := t.spanNs(&web, Web, scopeNodeUndici, "GET", ptrace.SpanKindClient, ms(2), ms(196),
		clientAttrs("GET", "http://localhost:5080/stock?sku=SKU-1042", 200))
	api := t.spanNs(&call, CheckoutAPI, scopeAspNetCore, "GET /stock", ptrace.SpanKindServer, ms(4), ms(192),
		serverAttrs("GET", "/stock", "/stock", 200))
	for i, d := range []float64{3, 3, 120} { // the third is also Slow SQL
		t.spanNs(&api, CheckoutAPI, scopeEFCore, "SELECT inventory", ptrace.SpanKindClient, ms(6+4*float64(i)), ms(d),
			efAttrs("SELECT", "inventory", stmt))
	}
	out := t.spanNs(&api, CheckoutAPI, scopeHTTPClient, "GET", ptrace.SpanKindClient, ms(136), ms(58),
		clientAttrs("GET", "http://localhost:8081/v1/stock/SKU-1042", 200))
	srv := t.spanNs(&out, Orders, scopeOtelHTTP, "GET /v1/stock/{sku}", ptrace.SpanKindServer, ms(138), ms(54), map[string]any{
		"http.method": "GET", "http.route": "/v1/stock/{sku}", "http.target": "/v1/stock/SKU-1042", "http.status_code": 200,
	})
	for i := range 3 {
		t.spanNs(&srv, Orders, scopeOtelSQL, "SELECT inventory", ptrace.SpanKindClient, ms(140+6*float64(i)), ms(4),
			goSQLAttrs("SELECT", "inventory", stmt))
	}
}

func edgeHTTP4xx(t *Trace) {
	web := t.spanNs(nil, Web, scopeNodeHTTP, "GET /edge/profile", ptrace.SpanKindServer, 0, ms(60),
		serverAttrs("GET", "/edge/profile", "/edge/profile", 200))
	// Client spans: 4xx is status Error. Server spans: 4xx stays Unset (semantic conventions).
	missing := t.spanNs(&web, Web, scopeNodeUndici, "GET", ptrace.SpanKindClient, ms(2), ms(20),
		clientAttrs("GET", "http://localhost:5080/customers/404", 404))
	setError(missing, "")
	t.spanNs(&missing, CheckoutAPI, scopeAspNetCore, "GET /customers/{id}", ptrace.SpanKindServer, ms(4), ms(16),
		serverAttrs("GET", "/customers/{id}", "/customers/404", 404))
	cached := t.spanNs(&web, Web, scopeNodeUndici, "GET", ptrace.SpanKindClient, ms(24), ms(10),
		clientAttrs("GET", "http://localhost:5080/customers/77/avatar", 304))
	t.spanNs(&cached, CheckoutAPI, scopeAspNetCore, "GET /customers/{id}/avatar", ptrace.SpanKindServer, ms(25), ms(8),
		serverAttrs("GET", "/customers/{id}/avatar", "/customers/77/avatar", 304))
	invalid := t.spanNs(&web, Web, scopeNodeUndici, "POST", ptrace.SpanKindClient, ms(36), ms(20),
		clientAttrs("POST", "http://localhost:5080/customers/77/validate", 400))
	setError(invalid, "")
	t.spanNs(&invalid, CheckoutAPI, scopeAspNetCore, "POST /customers/{id}/validate", ptrace.SpanKindServer, ms(38), ms(16),
		serverAttrs("POST", "/customers/{id}/validate", "/customers/77/validate", 400))
}

func edgeHTTPNoCode(t *Trace) {
	api := t.spanNs(nil, CheckoutAPI, scopeAspNetCore, "POST /refunds", ptrace.SpanKindServer, 0, ms(30020),
		serverAttrs("POST", "/refunds", "/refunds", 502))
	setError(api, "")
	stripe := t.spanNs(&api, CheckoutAPI, scopeHTTPClient, "POST", ptrace.SpanKindClient, ms(8), ms(30000), map[string]any{
		"http.request.method": "POST", "url.full": "https://api.stripe.com/v1/refunds", "server.address": "api.stripe.com",
		"error.type": "System.Threading.Tasks.TaskCanceledException",
	})
	setError(stripe, "The request was canceled due to the configured HttpClient.Timeout of 30 seconds elapsing.")
}

func edgeHTTPOldConventions(t *Trace) {
	api := t.spanNs(nil, CheckoutAPI, scopeAspNetCore, "GET /stock/{sku}", ptrace.SpanKindServer, 0, ms(40),
		serverAttrs("GET", "/stock/{sku}", "/stock/SKU-9", 200))
	setError(api, "stock read from cache after orders failed")
	out := t.spanNs(&api, CheckoutAPI, scopeHTTPClient, "GET", ptrace.SpanKindClient, ms(2), ms(30),
		clientAttrs("GET", "http://localhost:8081/v1/stock/SKU-9", 503))
	setError(out, "")
	srv := t.spanNs(&out, Orders, scopeOtelHTTP, "GET /v1/stock/{sku}", ptrace.SpanKindServer, ms(4), ms(26), map[string]any{
		"http.method": "GET", "http.route": "/v1/stock/{sku}", "http.target": "/v1/stock/SKU-9", "http.status_code": 503,
	})
	setError(srv, "inventory database unavailable")
}
