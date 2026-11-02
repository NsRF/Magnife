package sample

import (
	"fmt"
	"hash/fnv"
	"time"

	"go.opentelemetry.io/collector/pdata/pcommon"
	"go.opentelemetry.io/collector/pdata/plog"
	"go.opentelemetry.io/collector/pdata/ptrace"
)

// Trace builds one trace into a batch. Offsets are milliseconds from Start,
// scaled by Scale so random traces vary while staying properly nested.
type Trace struct {
	ID    pcommon.TraceID
	Start time.Time
	Scale float64
	Spans int
	Logs  int

	g *Gen
	b *Batch
}

func (t *Trace) at(ms float64) pcommon.Timestamp {
	return pcommon.NewTimestampFromTime(t.Start.Add(time.Duration(ms * t.Scale * float64(time.Millisecond))))
}

// span adds a span; parent is nil for a root.
func (t *Trace) span(parent *ptrace.Span, svc *Service, sc Scope, name string, kind ptrace.SpanKind,
	startMs, durMs float64, attrs map[string]any) ptrace.Span {
	s := t.b.NewSpan(svc, sc)
	s.SetTraceID(t.ID)
	s.SetSpanID(t.g.SpanID())
	if parent != nil {
		s.SetParentSpanID(parent.SpanID())
	}
	s.SetName(name)
	s.SetKind(kind)
	s.SetStartTimestamp(t.at(startMs))
	s.SetEndTimestamp(t.at(startMs + durMs))
	putAll(s.Attributes(), attrs)
	t.Spans++
	return s
}

// Severity numbers and the text each SDK uses for them.
const (
	sevDebug = plog.SeverityNumberDebug
	sevInfo  = plog.SeverityNumberInfo
	sevWarn  = plog.SeverityNumberWarn
	sevError = plog.SeverityNumberError
)

func severityText(svc *Service, n plog.SeverityNumber) string {
	var names [4]string
	switch svc {
	case CheckoutAPI:
		names = [4]string{"Debug", "Information", "Warning", "Error"}
	case Orders:
		names = [4]string{"DEBUG", "INFO", "WARN", "ERROR"}
	default:
		names = [4]string{"debug", "info", "warn", "error"}
	}
	switch n {
	case sevDebug:
		return names[0]
	case sevInfo:
		return names[1]
	case sevWarn:
		return names[2]
	default:
		return names[3]
	}
}

// log adds a log record, linked to span when it is not nil.
func (t *Trace) log(span *ptrace.Span, svc *Service, sc Scope, sev plog.SeverityNumber, atMs float64,
	body string, attrs map[string]any) plog.LogRecord {
	l := t.b.NewLog(svc, sc)
	l.SetTimestamp(t.at(atMs))
	l.SetObservedTimestamp(t.at(atMs + 0.4))
	l.SetSeverityNumber(sev)
	l.SetSeverityText(severityText(svc, sev))
	l.Body().SetStr(body)
	putAll(l.Attributes(), attrs)
	if span != nil {
		l.SetTraceID(span.TraceID())
		l.SetSpanID(span.SpanID())
		l.SetFlags(plog.DefaultLogRecordFlags.WithIsSampled(true))
	}
	t.Logs++
	return l
}

func setError(s ptrace.Span, msg string) {
	s.Status().SetCode(ptrace.StatusCodeError)
	s.Status().SetMessage(msg)
}

func addException(t *Trace, s ptrace.Span, atMs float64, typ, msg, stack string) {
	ev := s.Events().AppendEmpty()
	ev.SetName("exception")
	ev.SetTimestamp(t.at(atMs))
	putAll(ev.Attributes(), map[string]any{
		"exception.type":       typ,
		"exception.message":    msg,
		"exception.stacktrace": stack,
	})
}

// Scenario is one kind of trace.
type Scenario struct {
	Name        string
	Description string
	build       func(t *Trace)
}

// Scenarios is the seed set, in the order the sender emits it.
var Scenarios = []Scenario{
	{"logs", "startup logs with no trace id", standaloneLogs},
	{"healthy", "web GET /checkout -> checkout-api POST /orders -> orders gRPC -> postgresql", healthy},
	{"n-plus-one", "orders runs the same SELECT for 8 order ids", nPlusOne},
	{"slow-query", "checkout-api runs an 850 ms report query", slowQuery},
	{"http-500", "POST /payments fails with 500 and a .NET exception", http500},
	{"exception", "an orders background job fails with a Go error", jobException},
}

// Lookup finds a scenario by name.
func Lookup(name string) (Scenario, bool) {
	for _, s := range Scenarios {
		if s.Name == name {
			return s, true
		}
	}
	return Scenario{}, false
}

// SeedGen returns the deterministic generator for a scenario of the seed
// set, so its ids do not depend on which other scenarios run.
func SeedGen(name string) *Gen {
	h := fnv.New64a()
	h.Write([]byte("magnife-seed/" + name))
	return NewGen(h.Sum64())
}

// Add builds the scenario's trace (and logs) into b, starting at start.
// scale stretches every offset and duration; 1 keeps them as written.
func (s Scenario) Add(g *Gen, b *Batch, start time.Time, scale float64) *Trace {
	t := &Trace{ID: g.TraceID(), Start: start, Scale: scale, g: g, b: b}
	s.build(t)
	return t
}

// ---- scenarios ------------------------------------------------------------

func standaloneLogs(t *Trace) {
	t.log(nil, CheckoutAPI, scopeNetHosting, sevInfo, 0, "Now listening on: http://localhost:5080", map[string]any{"address": "http://localhost:5080"})
	t.log(nil, CheckoutAPI, scopeNetHosting, sevInfo, 2, "Application started. Press Ctrl+C to shut down.", nil)
	t.log(nil, CheckoutAPI, scopeNetHosting, sevInfo, 2.5, "Hosting environment: Development", map[string]any{"envName": "Development"})
	t.log(nil, Orders, scopeGoSlog, sevInfo, 5, "grpc server listening", map[string]any{"addr": "127.0.0.1:9090"})
	t.log(nil, Orders, scopeGoSlog, sevWarn, 40, "database pool near capacity", map[string]any{"in_use": 18, "max_open": 20})
	t.log(nil, Web, scopeNodePino, sevDebug, 60, "hot reload: 3 modules updated", map[string]any{"modules": []string{"routes/checkout.js", "routes/orders.js", "lib/api.js"}})
	// A pino-style structured body, and a record with only an observed time.
	l := t.log(nil, Web, scopeNodePino, sevInfo, 8, "", nil)
	body := l.Body().SetEmptyMap()
	body.PutStr("msg", "server started")
	body.PutInt("port", 3000)
	body.PutStr("env", "development")
	l = t.log(nil, Orders, scopeGoSlog, sevDebug, 70, "config reloaded", map[string]any{"source": "orders.yaml"})
	l.SetTimestamp(0)
}

func healthy(t *Trace) {
	web := t.span(nil, Web, scopeNodeHTTP, "GET /checkout", ptrace.SpanKindServer, 0, 182, map[string]any{
		"http.request.method": "GET", "http.route": "/checkout", "url.path": "/checkout", "url.query": "step=review",
		"url.scheme": "http", "server.address": "localhost", "server.port": 3000, "http.response.status_code": 200,
		"network.protocol.version": "1.1", "client.address": "127.0.0.1",
		"user_agent.original": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15",
	})
	handler := t.span(&web, Web, scopeNodeExpress, "request handler - /checkout", ptrace.SpanKindInternal, 2, 178, map[string]any{
		"express.name": "/checkout", "express.type": "request_handler", "http.route": "/checkout",
	})
	call := t.span(&handler, Web, scopeNodeUndici, "POST", ptrace.SpanKindClient, 5, 170, map[string]any{
		"http.request.method": "POST", "url.full": "http://localhost:5080/orders", "server.address": "localhost",
		"server.port": 5080, "http.response.status_code": 201, "network.peer.address": "127.0.0.1",
	})
	api := t.span(&call, CheckoutAPI, scopeAspNetCore, "POST /orders", ptrace.SpanKindServer, 8, 164, map[string]any{
		"http.request.method": "POST", "http.route": "/orders", "url.path": "/orders", "url.scheme": "http",
		"server.address": "localhost", "server.port": 5080, "network.protocol.version": "1.1",
		"http.response.status_code": 201, "user_agent.original": "node",
	})
	cart := t.span(&api, CheckoutAPI, scopeEFCore, "SELECT Carts", ptrace.SpanKindClient, 12, 4.2, efAttrs("SELECT",
		"Carts", `SELECT c."Id", c."CustomerId", c."CreatedAt" FROM "Carts" AS c WHERE c."Id" = @__cartId_0 LIMIT 1`))
	t.span(&api, CheckoutAPI, scopeEFCore, "SELECT CartItems", ptrace.SpanKindClient, 17, 5.1, efAttrs("SELECT",
		"CartItems", `SELECT i."Id", i."Sku", i."Quantity", i."UnitPriceCents" FROM "CartItems" AS i WHERE i."CartId" = @__cartId_0`))
	t.log(&cart, CheckoutAPI, scopeNetLogs, sevInfo, 16.5, "Creating order for cart 7f3c9a1e", map[string]any{
		"CartId": "7f3c9a1e", "CustomerId": 77, "{OriginalFormat}": "Creating order for cart {CartId}",
	})
	rpc := t.span(&api, CheckoutAPI, scopeGrpcNet, "orders.v1.OrderService/CreateOrder", ptrace.SpanKindClient, 25, 125, map[string]any{
		"rpc.system": "grpc", "rpc.service": "orders.v1.OrderService", "rpc.method": "CreateOrder",
		"rpc.grpc.status_code": 0, "server.address": "localhost", "server.port": 9090,
	})
	srv := t.span(&rpc, Orders, scopeOtelGRPC, "orders.v1.OrderService/CreateOrder", ptrace.SpanKindServer, 28, 119, map[string]any{
		"rpc.system": "grpc", "rpc.service": "orders.v1.OrderService", "rpc.method": "CreateOrder",
		"rpc.grpc.status_code": 0, "net.sock.peer.addr": "127.0.0.1", "net.sock.peer.port": 52814,
	})
	t.span(&srv, Orders, scopeOtelSQL, "INSERT orders", ptrace.SpanKindClient, 32, 9, goSQLAttrs("INSERT", "orders",
		"INSERT INTO orders (customer_id, cart_id, total_cents, status) VALUES ($1, $2, $3, $4) RETURNING id"))
	t.span(&srv, Orders, scopeOtelSQL, "INSERT order_items", ptrace.SpanKindClient, 42, 13, goSQLAttrs("INSERT", "order_items",
		"INSERT INTO order_items (order_id, sku, quantity, unit_price_cents) VALUES ($1, $2, $3, $4), ($5, $6, $7, $8)"))
	inv := t.span(&srv, Orders, scopeOtelSQL, "SELECT inventory", ptrace.SpanKindClient, 56, 14, goSQLAttrs("SELECT", "inventory",
		"SELECT sku, available FROM inventory WHERE sku = ANY($1) FOR UPDATE"))
	t.log(&inv, Orders, scopeGoSlog, sevDebug, 57, "reserving inventory", map[string]any{"skus": []string{"SKU-1042", "SKU-2210"}})
	t.log(&srv, Orders, scopeGoSlog, sevInfo, 146, "order created", map[string]any{"order_id": 1042, "total_cents": 8497})
	t.span(&api, CheckoutAPI, scopeEFCore, "INSERT OutboxMessages", ptrace.SpanKindClient, 152, 8, efAttrs("INSERT",
		"OutboxMessages", `INSERT INTO "OutboxMessages" ("Id", "Type", "Payload", "CreatedAt") VALUES (@p0, @p1, @p2, @p3)`))
	t.log(&handler, Web, scopeNodePino, sevInfo, 179, "checkout rendered", map[string]any{"order_id": 1042, "duration_ms": 177})
}

func nPlusOne(t *Trace) {
	web := t.span(nil, Web, scopeNodeHTTP, "GET /account/orders", ptrace.SpanKindServer, 0, 96, map[string]any{
		"http.request.method": "GET", "http.route": "/account/orders", "url.path": "/account/orders",
		"url.scheme": "http", "server.address": "localhost", "server.port": 3000, "http.response.status_code": 200,
	})
	call := t.span(&web, Web, scopeNodeUndici, "GET", ptrace.SpanKindClient, 3, 90, map[string]any{
		"http.request.method": "GET", "url.full": "http://localhost:5080/orders/history?customerId=77",
		"server.address": "localhost", "server.port": 5080, "http.response.status_code": 200,
	})
	api := t.span(&call, CheckoutAPI, scopeAspNetCore, "GET /orders/history", ptrace.SpanKindServer, 5, 86, map[string]any{
		"http.request.method": "GET", "http.route": "/orders/history", "url.path": "/orders/history",
		"url.query": "customerId=77", "url.scheme": "http", "http.response.status_code": 200,
	})
	out := t.span(&api, CheckoutAPI, scopeHTTPClient, "GET", ptrace.SpanKindClient, 7, 81, map[string]any{
		"http.request.method": "GET", "url.full": "http://localhost:8081/v1/orders?customer_id=77",
		"server.address": "localhost", "server.port": 8081, "http.response.status_code": 200,
	})
	srv := t.span(&out, Orders, scopeOtelHTTP, "GET /v1/orders", ptrace.SpanKindServer, 9, 77, map[string]any{
		"http.method": "GET", "http.route": "/v1/orders", "http.target": "/v1/orders?customer_id=77",
		"http.scheme": "http", "http.status_code": 200, "net.host.name": "localhost", "net.host.port": 8081,
		"http.user_agent": "System.Net.Http/9.0",
	})
	t.span(&srv, Orders, scopeOtelSQL, "SELECT orders", ptrace.SpanKindClient, 11, 6, goSQLAttrs("SELECT", "orders",
		"SELECT id, status, total_cents, created_at FROM orders WHERE customer_id = 77 ORDER BY created_at DESC LIMIT 8"))
	for i := range 8 {
		t.span(&srv, Orders, scopeOtelSQL, "SELECT order_items", ptrace.SpanKindClient, 18+float64(i)*8, 7.2, goSQLAttrs("SELECT", "order_items",
			fmt.Sprintf("SELECT * FROM order_items WHERE order_id = %d", 1042+i)))
	}
	t.log(&srv, Orders, scopeGoSlog, sevDebug, 84, "loaded order history", map[string]any{"customer_id": 77, "orders": 8})
}

func slowQuery(t *Trace) {
	web := t.span(nil, Web, scopeNodeHTTP, "GET /admin/reports", ptrace.SpanKindServer, 0, 884, map[string]any{
		"http.request.method": "GET", "http.route": "/admin/reports", "url.path": "/admin/reports",
		"url.scheme": "http", "server.address": "localhost", "server.port": 3000, "http.response.status_code": 200,
	})
	call := t.span(&web, Web, scopeNodeUndici, "GET", ptrace.SpanKindClient, 4, 874, map[string]any{
		"http.request.method": "GET", "url.full": "http://localhost:5080/reports/sales?days=30",
		"server.address": "localhost", "server.port": 5080, "http.response.status_code": 200,
	})
	api := t.span(&call, CheckoutAPI, scopeAspNetCore, "GET /reports/sales", ptrace.SpanKindServer, 6, 869, map[string]any{
		"http.request.method": "GET", "http.route": "/reports/sales", "url.path": "/reports/sales",
		"url.query": "days=30", "url.scheme": "http", "http.response.status_code": 200,
	})
	q := t.span(&api, CheckoutAPI, scopeEFCore, "SELECT Orders", ptrace.SpanKindClient, 11, 851, efAttrs("SELECT", "Orders",
		`SELECT date_trunc('day', o."CreatedAt") AS "Day", count(*)::int AS "Orders", sum(o."TotalCents") AS "Revenue" `+
			`FROM "Orders" AS o WHERE o."CreatedAt" >= @__since_0 GROUP BY date_trunc('day', o."CreatedAt") ORDER BY 1`))
	t.log(&q, CheckoutAPI, scopeNetEFCmd, sevWarn, 862, "Executed DbCommand (851ms) [Parameters=[@__since_0='?' (DbType = DateTime)], CommandType='Text', CommandTimeout='30']", map[string]any{
		"elapsed": "851", "commandType": "Text", "commandTimeout": 30, "EventId.Id": 20101, "EventId.Name": "Microsoft.EntityFrameworkCore.Database.Command.CommandExecuted",
	})
}

func http500(t *Trace) {
	web := t.span(nil, Web, scopeNodeHTTP, "POST /checkout/pay", ptrace.SpanKindServer, 0, 64, map[string]any{
		"http.request.method": "POST", "http.route": "/checkout/pay", "url.path": "/checkout/pay",
		"url.scheme": "http", "server.address": "localhost", "server.port": 3000, "http.response.status_code": 500,
	})
	setError(web, "")
	call := t.span(&web, Web, scopeNodeUndici, "POST", ptrace.SpanKindClient, 3, 57, map[string]any{
		"http.request.method": "POST", "url.full": "http://localhost:5080/payments", "server.address": "localhost",
		"server.port": 5080, "http.response.status_code": 500, "error.type": "500",
	})
	setError(call, "")
	api := t.span(&call, CheckoutAPI, scopeAspNetCore, "POST /payments", ptrace.SpanKindServer, 5, 52, map[string]any{
		"http.request.method": "POST", "http.route": "/payments", "url.path": "/payments", "url.scheme": "http",
		"server.address": "localhost", "server.port": 5080, "http.response.status_code": 500,
		"error.type": "Microsoft.EntityFrameworkCore.DbUpdateException",
	})
	setError(api, "")
	t.span(&api, CheckoutAPI, scopeEFCore, "SELECT Orders", ptrace.SpanKindClient, 9, 3.4, efAttrs("SELECT", "Orders",
		`SELECT o."Id", o."Status", o."TotalCents" FROM "Orders" AS o WHERE o."Id" = @__orderId_0 LIMIT 1`))
	ins := t.span(&api, CheckoutAPI, scopeEFCore, "INSERT Payments", ptrace.SpanKindClient, 15, 6.8, efAttrs("INSERT", "Payments",
		`INSERT INTO "Payments" ("Id", "OrderId", "AmountCents", "Provider", "CreatedAt") VALUES (@p0, @p1, @p2, @p3, @p4)`))
	ins.Attributes().PutStr("db.response.status_code", "23505")
	ins.Attributes().PutStr("error.type", "Npgsql.PostgresException")
	setError(ins, `23505: duplicate key value violates unique constraint "IX_Payments_OrderId"`)
	addException(t, api, 23, "Microsoft.EntityFrameworkCore.DbUpdateException",
		"An error occurred while saving the entity changes. See the inner exception for details.", dotnetStack)
	t.log(&ins, CheckoutAPI, scopeNetPay, sevWarn, 22, "Payment for order 1042 was not saved", map[string]any{
		"OrderId": 1042, "Provider": "stripe", "{OriginalFormat}": "Payment for order {OrderId} was not saved",
	})
	t.log(&api, CheckoutAPI, scopeNetDiag, sevError, 24, "An unhandled exception has occurred while executing the request.", map[string]any{
		"exception.type":    "Microsoft.EntityFrameworkCore.DbUpdateException",
		"exception.message": "An error occurred while saving the entity changes. See the inner exception for details.",
		"EventId.Id":        1, "EventId.Name": "UnhandledException",
	})
	t.log(&call, Web, scopeNodePino, sevError, 61, "payment request failed", map[string]any{"status": 500, "order_id": 1042})
}

func jobException(t *Trace) {
	job := t.span(nil, Orders, scopeGoJobs, "inventory.reconcile", ptrace.SpanKindInternal, 0, 2012, map[string]any{
		"job.name": "inventory.reconcile", "job.run_id": "run-20261102-0142", "inventory.skus": 214,
	})
	upd := t.span(&job, Orders, scopeOtelSQL, "UPDATE inventory", ptrace.SpanKindClient, 6, 2000, goSQLAttrs("UPDATE", "inventory",
		"UPDATE inventory SET available = available - $1, updated_at = now() WHERE sku = $2"))
	setError(upd, "context deadline exceeded")
	setError(job, "reconcile inventory: update sku SKU-1042: context deadline exceeded")
	addException(t, job, 2008, "*fmt.wrapError",
		"reconcile inventory: update sku SKU-1042: context deadline exceeded", goStack)
	t.log(&job, Orders, scopeGoSlog, sevError, 2009, "reconcile failed", map[string]any{
		"err": "reconcile inventory: update sku SKU-1042: context deadline exceeded", "sku": "SKU-1042",
	})
}

// efAttrs are EF Core / Npgsql attributes in the new conventions.
func efAttrs(op, table, query string) map[string]any {
	return map[string]any{
		"db.system.name": "postgresql", "db.namespace": "shop", "db.operation.name": op,
		"db.collection.name": table, "db.query.text": query,
		"server.address": "localhost", "server.port": 5432,
	}
}

// goSQLAttrs are otelsql attributes in the old conventions.
func goSQLAttrs(op, table, stmt string) map[string]any {
	return map[string]any{
		"db.system": "postgresql", "db.name": "orders", "db.operation": op, "db.sql.table": table,
		"db.statement": stmt, "net.peer.name": "localhost", "net.peer.port": 5432,
	}
}

const dotnetStack = `Microsoft.EntityFrameworkCore.DbUpdateException: An error occurred while saving the entity changes. See the inner exception for details.
 ---> Npgsql.PostgresException (0x80004005): 23505: duplicate key value violates unique constraint "IX_Payments_OrderId"

DETAIL: Detail redacted as it may contain sensitive data. Specify 'Include Error Detail' in the connection string to include this information.
   at Npgsql.Internal.NpgsqlConnector.ReadMessageLong(Boolean async, DataRowLoadingMode dataRowLoadingMode, Boolean readingNotifications, Boolean isReadingPrependedMessage)
   at System.Runtime.CompilerServices.PoolingAsyncValueTaskMethodBuilder` + "`" + `1.StateMachineBox` + "`" + `1.System.Threading.Tasks.Sources.IValueTaskSource<TResult>.GetResult(Int16 token)
   at Npgsql.NpgsqlDataReader.NextResult(Boolean async, Boolean isConsuming, CancellationToken cancellationToken)
   at Npgsql.NpgsqlCommand.ExecuteReader(Boolean async, CommandBehavior behavior, CancellationToken cancellationToken)
   at Microsoft.EntityFrameworkCore.Storage.RelationalCommand.ExecuteReaderAsync(RelationalCommandParameterObject parameterObject, CancellationToken cancellationToken)
   at Microsoft.EntityFrameworkCore.Update.ReaderModificationCommandBatch.ExecuteAsync(IRelationalConnection connection, CancellationToken cancellationToken)
  Exception data:
    Severity: ERROR
    SqlState: 23505
    MessageText: duplicate key value violates unique constraint "IX_Payments_OrderId"
    SchemaName: public
    TableName: Payments
    ConstraintName: IX_Payments_OrderId
   --- End of inner exception stack trace ---
   at Microsoft.EntityFrameworkCore.Update.ReaderModificationCommandBatch.ExecuteAsync(IRelationalConnection connection, CancellationToken cancellationToken)
   at Microsoft.EntityFrameworkCore.Update.Internal.BatchExecutor.ExecuteAsync(IEnumerable` + "`" + `1 commandBatches, IRelationalConnection connection, CancellationToken cancellationToken)
   at Microsoft.EntityFrameworkCore.ChangeTracking.Internal.StateManager.SaveChangesAsync(IList` + "`" + `1 entriesToSave, CancellationToken cancellationToken)
   at Microsoft.EntityFrameworkCore.DbContext.SaveChangesAsync(Boolean acceptAllChangesOnSuccess, CancellationToken cancellationToken)
   at Checkout.Api.Payments.PaymentService.CaptureAsync(Guid orderId, PaymentRequest request, CancellationToken ct) in /Users/dev/shop/checkout-api/src/Checkout.Api/Payments/PaymentService.cs:line 87
   at Checkout.Api.Payments.PaymentEndpoints.<>c.<<MapPayments>b__0_0>d.MoveNext() in /Users/dev/shop/checkout-api/src/Checkout.Api/Payments/PaymentEndpoints.cs:line 24
--- End of stack trace from previous location ---
   at Microsoft.AspNetCore.Http.RequestDelegateFactory.ExecuteTaskResult[T](Task` + "`" + `1 task, HttpContext httpContext)
   at Microsoft.AspNetCore.Routing.EndpointMiddleware.<Invoke>g__AwaitRequestTask|7_0(Endpoint endpoint, Task requestTask, ILogger logger)
   at Microsoft.AspNetCore.Diagnostics.DeveloperExceptionPageMiddlewareImpl.Invoke(HttpContext context)`

const goStack = `goroutine 87 [running]:
runtime/debug.Stack()
	/opt/homebrew/Cellar/go/1.27.3/libexec/src/runtime/debug/stack.go:26 +0x64
orders/internal/telemetry.RecordError({0x1050a8f40, 0x14000312a80}, {0x1050a1e20, 0x140002b6f60})
	/Users/dev/shop/orders/internal/telemetry/errors.go:31 +0x88
orders/internal/jobs.(*Reconciler).Run(0x14000188e00, {0x1050a8f40, 0x14000312a80})
	/Users/dev/shop/orders/internal/jobs/reconcile.go:88 +0x3d4
orders/internal/jobs.(*Scheduler).runOnce(0x140001a2000, {0x1050a8ed0, 0x140000ba0a0}, 0x14000188e00)
	/Users/dev/shop/orders/internal/jobs/scheduler.go:142 +0x1b0
created by orders/internal/jobs.(*Scheduler).Start in goroutine 1
	/Users/dev/shop/orders/internal/jobs/scheduler.go:97 +0x2a8`
