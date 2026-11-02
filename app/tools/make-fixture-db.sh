#!/bin/zsh
# Builds a small, realistic Magnife database in /tmp for snapshots and the
# self-test, the way the helper would write it (docs/schema.sql, WAL mode).
# The app never writes its database, so seed data is made here, outside it.
# Usage: tools/make-fixture-db.sh /tmp/Magnife-test.sqlite           10 traces, 3 services, logs
#        tools/make-fixture-db.sh /tmp/Magnife-empty.sqlite --empty  schema only
# Times are relative to now, so the list reads "25 s ago", "2 min ago", and clock times.
set -euo pipefail
out=${1:?usage: make-fixture-db.sh <file in /tmp> [--empty]}
[[ ${out:A} == /tmp/* || ${out:A} == /private/tmp/* ]] || { echo "refused: the fixture goes in /tmp"; exit 1; }
schema=${0:A:h:h:h}/docs/schema.sql
[[ -f $schema ]] || { echo "missing $schema"; exit 1; }
# Apple's sqlite3 keeps the -wal file after it exits; a read-only reader
# cannot open a WAL database without it (WALReadonlyTests).
sqlite=/usr/bin/sqlite3
rm -f $out $out-wal $out-shm
mkdir -p ${out:h}

{
  echo "PRAGMA journal_mode = WAL;"
  cat $schema
  echo "INSERT INTO meta (key, value) VALUES ('schema_version', '1'), ('retention_s', '86400');"
  if [[ ${2:-} == --empty ]]; then
    echo "INSERT INTO meta (key, value) VALUES ('last_seq', '0');"
  else
    cat <<'SQL'
BEGIN;
CREATE TEMP TABLE clock AS SELECT CAST(unixepoch('subsec') * 1000 AS INTEGER) * 1000000 AS now;

INSERT INTO resources (id, hash, service_name, attributes) VALUES
 (1, 'fixture-checkout-api', 'checkout-api', json_object('service.name', 'checkout-api', 'service.version', '1.4.2',
   'telemetry.sdk.language', 'dotnet', 'telemetry.sdk.name', 'opentelemetry', 'telemetry.sdk.version', '1.12.0',
   'host.name', 'nasser-mbp.local', 'deployment.environment.name', 'development')),
 (2, 'fixture-orders', 'orders', json_object('service.name', 'orders', 'service.version', '0.9.0',
   'telemetry.sdk.language', 'go', 'telemetry.sdk.name', 'opentelemetry', 'telemetry.sdk.version', '1.38.0',
   'host.name', 'nasser-mbp.local')),
 (3, 'fixture-web', 'web', json_object('service.name', 'web', 'service.version', '2.1.0',
   'telemetry.sdk.language', 'nodejs', 'telemetry.sdk.name', 'opentelemetry', 'telemetry.sdk.version', '2.2.0',
   'host.name', 'nasser-mbp.local'));

-- One row per span: trace number, span number, parent span number, how long
-- ago the trace started (ms), offset into the trace and duration (us).
CREATE TEMP TABLE f (t, s, p, name, kind, ago_ms, off_us, dur_us, status, msg, res,
                     method, code, route, url, dbsys, stmt, extra, events);
INSERT INTO f VALUES
 -- 1 healthy: web -> checkout-api -> postgres
 (1, 1, NULL, 'GET /products', 2, 25000, 0, 84000, 0, '', 3, 'GET', 200, '/products', NULL, NULL, NULL, NULL, NULL),
 (1, 2, 1, 'GET', 3, 25000, 2000, 78000, 0, '', 3, 'GET', 200, NULL, 'http://localhost:5080/api/products', NULL, NULL, NULL, NULL),
 (1, 3, 2, 'GET /api/products', 2, 25000, 4000, 72000, 0, '', 1, 'GET', 200, '/api/products', NULL, NULL, NULL, NULL, NULL),
 (1, 4, 3, 'SELECT shop.products', 3, 25000, 10000, 18000, 0, '', 1, NULL, NULL, NULL, NULL, 'postgresql',
  'SELECT id, name, price FROM products WHERE active = true', '{"db.namespace":"shop"}', NULL),
 -- 2 error with an exception: checkout-api POST /orders
 (2, 1, NULL, 'POST /orders', 2, 120000, 0, 240000, 2, 'Sequence contains no elements', 1, 'POST', 500, '/orders', NULL, NULL, NULL, NULL, 'exception'),
 (2, 2, 1, 'SELECT shop.carts', 3, 120000, 6000, 7000, 0, '', 1, NULL, NULL, NULL, NULL, 'postgresql',
  'SELECT * FROM carts WHERE customer_id = @customerId', NULL, NULL),
 (2, 3, 1, 'POST', 3, 120000, 16000, 44000, 0, '', 1, 'POST', 200, NULL, 'http://localhost:9000/reserve', NULL, NULL, NULL, NULL),
 (2, 4, 3, 'POST /reserve', 2, 120000, 20000, 36000, 0, '', 2, 'POST', 200, '/reserve', NULL, NULL, NULL, NULL, NULL),
 (2, 5, 4, 'INSERT shop.reservations', 3, 120000, 28000, 9000, 0, '', 2, NULL, NULL, NULL, NULL, 'postgresql',
  'INSERT INTO reservations (order_id, sku, qty) VALUES ($1, $2, $3)', NULL, NULL),
 (2, 6, 1, 'DiscountService.Apply', 1, 120000, 64000, 170000, 2, 'Sequence contains no elements', 1,
  NULL, NULL, NULL, NULL, NULL, NULL, '{"code.function.name":"Checkout.Discounts.DiscountService.Apply"}', NULL),
 -- 3 slow SQL
 (3, 1, NULL, 'GET /api/orders/{id}', 2, 300000, 0, 1310000, 1, '', 1, 'GET', 200, '/api/orders/{id}', NULL, NULL, NULL, NULL, NULL),
 (3, 2, 1, 'GET', 3, 300000, 3000, 400, 0, '', 1, NULL, NULL, NULL, NULL, 'redis', 'GET order:7781',
  '{"server.address":"localhost","server.port":6379}', NULL),
 (3, 3, 1, 'SELECT shop.orders', 3, 300000, 8000, 1240000, 0, '', 1, NULL, NULL, NULL, NULL, 'postgresql',
  'SELECT o.*, i.* FROM orders o JOIN order_items i ON i.order_id = o.id WHERE o.customer_id = @customerId ORDER BY o.created_at DESC',
  NULL, NULL),
 -- 4 N+1: the same statement 8 times
 (4, 1, NULL, 'GET /orders', 2, 480000, 0, 96000, 0, '', 2, 'GET', 200, '/orders', NULL, NULL, NULL, NULL, NULL),
 (4, 2, 1, 'SELECT shop.orders', 3, 480000, 2000, 9000, 0, '', 2, NULL, NULL, NULL, NULL, 'postgresql',
  'SELECT id, total FROM orders WHERE customer_id = $1 LIMIT 8', NULL, NULL),
 (4, 3, 1, 'SELECT shop.order_items', 3, 480000, 12000, 8000, 0, '', 2, NULL, NULL, NULL, NULL, 'postgresql', 'SELECT * FROM order_items WHERE order_id = $1', NULL, NULL),
 (4, 4, 1, 'SELECT shop.order_items', 3, 480000, 21000, 8000, 0, '', 2, NULL, NULL, NULL, NULL, 'postgresql', 'SELECT * FROM order_items WHERE order_id = $1', NULL, NULL),
 (4, 5, 1, 'SELECT shop.order_items', 3, 480000, 30000, 9000, 0, '', 2, NULL, NULL, NULL, NULL, 'postgresql', 'SELECT * FROM order_items WHERE order_id = $1', NULL, NULL),
 (4, 6, 1, 'SELECT shop.order_items', 3, 480000, 40000, 8000, 0, '', 2, NULL, NULL, NULL, NULL, 'postgresql', 'SELECT * FROM order_items WHERE order_id = $1', NULL, NULL),
 (4, 7, 1, 'SELECT shop.order_items', 3, 480000, 49000, 9000, 0, '', 2, NULL, NULL, NULL, NULL, 'postgresql', 'SELECT * FROM order_items WHERE order_id = $1', NULL, NULL),
 (4, 8, 1, 'SELECT shop.order_items', 3, 480000, 59000, 8000, 0, '', 2, NULL, NULL, NULL, NULL, 'postgresql', 'SELECT * FROM order_items WHERE order_id = $1', NULL, NULL),
 (4, 9, 1, 'SELECT shop.order_items', 3, 480000, 68000, 9000, 0, '', 2, NULL, NULL, NULL, NULL, 'postgresql', 'SELECT * FROM order_items WHERE order_id = $1', NULL, NULL),
 (4, 10, 1, 'SELECT shop.order_items', 3, 480000, 78000, 8000, 0, '', 2, NULL, NULL, NULL, NULL, 'postgresql', 'SELECT * FROM order_items WHERE order_id = $1', NULL, NULL),
 -- 5 failed HTTP call: the payment provider answers 500
 (5, 1, NULL, 'POST /payments', 2, 720000, 0, 612000, 2, '', 1, 'POST', 502, '/payments', NULL, NULL, NULL, NULL, NULL),
 (5, 2, 1, 'POST', 3, 720000, 4000, 301000, 2, 'HTTP 500', 1, 'POST', 500, NULL, 'https://api.payments.example/v1/charges', NULL, NULL, NULL, NULL),
 (5, 3, 1, 'POST', 3, 720000, 308000, 298000, 2, 'HTTP 500', 1, 'POST', 500, NULL, 'https://api.payments.example/v1/charges', NULL, NULL,
  '{"http.request.resend_count":1}', NULL),
 -- 6 to 10 healthy, older
 (6, 1, NULL, 'GET /', 2, 1080000, 0, 31000, 0, '', 3, 'GET', 200, '/', NULL, NULL, NULL, NULL, NULL),
 (6, 2, 1, 'render home', 1, 1080000, 3000, 24000, 0, '', 3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
 (7, 1, NULL, 'GET /health', 2, 1560000, 0, 400, 0, '', 2, 'GET', 200, '/health', NULL, NULL, NULL, NULL, NULL),
 (8, 1, NULL, 'GET /api/cart', 2, 2460000, 0, 22000, 1, '', 1, 'GET', 200, '/api/cart', NULL, NULL, NULL, NULL, NULL),
 (8, 2, 1, 'GET', 3, 2460000, 1000, 800, 0, '', 1, NULL, NULL, NULL, NULL, 'redis', 'GET cart:1042', NULL, NULL),
 (8, 3, 1, 'SELECT shop.carts', 3, 2460000, 4000, 12000, 0, '', 1, NULL, NULL, NULL, NULL, 'postgresql',
  'SELECT * FROM carts WHERE customer_id = @customerId', NULL, NULL),
 (9, 1, NULL, 'GET /account', 2, 4500000, 0, 140000, 0, '', 3, 'GET', 200, '/account', NULL, NULL, NULL, NULL, NULL),
 (9, 2, 1, 'GET', 3, 4500000, 3000, 131000, 0, '', 3, 'GET', 200, NULL, 'http://localhost:5080/api/account', NULL, NULL, NULL, NULL),
 (9, 3, 2, 'GET /api/account', 2, 4500000, 5000, 126000, 0, '', 1, 'GET', 200, '/api/account', NULL, NULL, NULL, NULL, NULL),
 (9, 4, 3, 'SELECT shop.customers', 3, 4500000, 11000, 96000, 0, '', 1, NULL, NULL, NULL, NULL, 'postgresql',
  'SELECT * FROM customers WHERE id = @id', NULL, NULL),
 (10, 1, NULL, 'process order', 5, 10800000, 0, 410000, 1, '', 2, NULL, NULL, NULL, NULL, NULL, NULL,
  '{"messaging.system":"rabbitmq","messaging.destination.name":"orders.created"}', NULL),
 (10, 2, 1, 'UPDATE shop.orders', 3, 10800000, 380000, 21000, 0, '', 2, NULL, NULL, NULL, NULL, 'postgresql',
  'UPDATE orders SET status = $1 WHERE id = $2', NULL, NULL);

INSERT INTO spans (trace_id, span_id, parent_span_id, name, kind, start_ns, end_ns, duration_ns, status_code,
                   status_message, service_name, resource_id, scope_name, scope_version, attributes, events,
                   db_system, db_statement, http_method, http_status_code, http_route, http_url, received_ns)
SELECT printf('4bf92f3577b34da6a3ce929d0e0e%04x', t),
       printf('00f067aa0ba9%04x', t * 16 + s),
       CASE WHEN p IS NULL THEN NULL ELSE printf('00f067aa0ba9%04x', t * 16 + p) END,
       name, kind,
       now - ago_ms * 1000000 + off_us * 1000,
       now - ago_ms * 1000000 + (off_us + dur_us) * 1000,
       dur_us * 1000, status, msg,
       (SELECT service_name FROM resources WHERE id = res), res,
       CASE res WHEN 1 THEN 'Microsoft.AspNetCore' WHEN 2 THEN 'go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp'
                ELSE '@opentelemetry/instrumentation-http' END, '',
       json_patch(COALESCE(extra, '{}'), json_object('http.request.method', method, 'http.response.status_code', code,
                  'http.route', route, 'url.full', url, 'db.system.name', dbsys, 'db.query.text', stmt)),
       CASE events WHEN 'exception' THEN json_array(json_object(
           'time_ns', now - ago_ms * 1000000 + 233000 * 1000, 'name', 'exception',
           'attributes', json_object(
               'exception.type', 'System.InvalidOperationException',
               'exception.message', 'Sequence contains no elements',
               'exception.stacktrace', 'System.InvalidOperationException: Sequence contains no elements' || char(10) ||
                 '   at System.Linq.ThrowHelper.ThrowNoElementsException()' || char(10) ||
                 '   at System.Linq.Enumerable.First[TSource](IEnumerable`1 source)' || char(10) ||
                 '   at Checkout.Discounts.DiscountService.Apply(Cart cart) in /src/Checkout/Discounts/DiscountService.cs:line 42' || char(10) ||
                 '   at Checkout.Orders.OrdersController.Create(CreateOrderRequest request) in /src/Checkout/Orders/OrdersController.cs:line 88' || char(10) ||
                 '   at Microsoft.AspNetCore.Mvc.Infrastructure.ActionMethodExecutor.TaskOfIActionResultExecutor.Execute(ActionContext context)')))
            ELSE '[]' END,
       dbsys, stmt, method, code, route, url,
       now - ago_ms * 1000000 + (off_us + dur_us) * 1000 + 50000000
FROM f, clock;

-- Trace rows, recomputed from spans with the helper's rules (docs/schema.sql).
INSERT INTO traces (trace_id, root_span_id, root_service, route, start_ns, end_ns, duration_ns, span_count,
                    error_count, status, first_seq, updated_seq, received_ns)
SELECT r.trace_id, r.span_id, r.service_name,
       CASE WHEN r.http_method IS NOT NULL AND r.http_route IS NOT NULL THEN r.http_method || ' ' || r.http_route
            ELSE COALESCE(r.http_route, r.name) END,
       a.start_ns, a.end_ns, a.end_ns - a.start_ns, a.span_count, a.error_count,
       CASE WHEN a.error_count > 0 THEN 2 ELSE r.status_code END,
       11 - a.t, 11 - a.t, a.received_ns
FROM spans r
JOIN (SELECT trace_id, (SELECT t FROM f WHERE printf('4bf92f3577b34da6a3ce929d0e0e%04x', f.t) = spans.trace_id LIMIT 1) AS t,
             MIN(start_ns) AS start_ns, MAX(end_ns) AS end_ns, COUNT(*) AS span_count,
             SUM(status_code = 2) AS error_count, MAX(received_ns) AS received_ns
      FROM spans GROUP BY trace_id) a ON a.trace_id = r.trace_id
WHERE r.parent_span_id IS NULL;

-- Logs: trace number (or NULL), span number, ms after the trace start (or ms ago), severity, service, body.
CREATE TEMP TABLE g (t, s, ms, sev, res, body, attrs);
INSERT INTO g VALUES
 (1, 1, 83, 9, 3, 'GET /products 200 in 84 ms', '{"http.response.status_code":200}'),
 (1, 3, 30, 5, 1, 'Loaded 24 products (cache miss)', NULL),
 (2, 1, 2, 9, 1, 'Creating order for customer 1042', '{"customer.id":1042}'),
 (2, 4, 30, 9, 2, 'Reserved 2 items for order 7781', '{"order.id":7781}'),
 (2, 6, 70, 13, 1, 'Discount rule set is empty for region EU', NULL),
 (2, 6, 233, 17, 1, 'Unhandled exception while creating order: Sequence contains no elements',
  '{"exception.type":"System.InvalidOperationException"}'),
 (3, 3, 1250, 13, 1, 'Slow query on shop.orders took 1240 ms', '{"db.system.name":"postgresql"}'),
 (4, 1, 1, 5, 2, 'Fetching items for 8 orders', NULL),
 (5, 2, 305, 17, 1, 'Payment provider returned 500 Internal Server Error', '{"http.response.status_code":500}'),
 (5, 1, 306, 13, 1, 'Retrying payment, attempt 2 of 2', NULL),
 (5, 3, 607, 17, 1, 'Payment failed after 2 attempts', NULL),
 (NULL, NULL, 10900000, 9, 2, 'Listening on 127.0.0.1:9000', NULL),
 (NULL, NULL, 10850000, 9, 3, 'Server started on http://localhost:3000', NULL),
 (NULL, NULL, 7200000, 13, 1, 'Configuration value Payments:TimeoutSeconds is missing; using 30', NULL),
 (NULL, NULL, 600000, 5, 3, 'Cache warmed with 120 entries', NULL);

INSERT INTO logs (time_ns, observed_ns, severity_number, severity_text, service_name, resource_id, scope_name,
                  body, attributes, trace_id, span_id, received_ns)
SELECT CASE WHEN t IS NULL THEN now - ms * 1000000
            ELSE (SELECT start_ns FROM traces WHERE trace_id = printf('4bf92f3577b34da6a3ce929d0e0e%04x', t)) + ms * 1000000 END,
       0, sev, CASE sev WHEN 5 THEN 'Debug' WHEN 9 THEN 'Information' WHEN 13 THEN 'Warning' ELSE 'Error' END,
       (SELECT service_name FROM resources WHERE id = res), res, '', body, COALESCE(attrs, '{}'),
       CASE WHEN t IS NULL THEN NULL ELSE printf('4bf92f3577b34da6a3ce929d0e0e%04x', t) END,
       CASE WHEN t IS NULL THEN NULL ELSE printf('00f067aa0ba9%04x', t * 16 + s) END,
       now
FROM g, clock
ORDER BY 1;

INSERT INTO services (name, first_seen_ns, last_seen_ns)
SELECT service_name, MIN(t), MAX(t) FROM (
  SELECT service_name, received_ns AS t FROM spans UNION ALL SELECT service_name, received_ns FROM logs)
GROUP BY service_name;

INSERT INTO attribute_keys (key, source, last_seen_ns)
SELECT key, 1, MAX(received_ns) FROM spans, json_each(spans.attributes) GROUP BY key
UNION ALL SELECT key, 2, (SELECT now FROM clock) FROM resources, json_each(resources.attributes) GROUP BY key
UNION ALL SELECT key, 3, MAX(received_ns) FROM logs, json_each(logs.attributes) GROUP BY key;

INSERT INTO meta (key, value) VALUES ('last_seq', '10');
COMMIT;
SQL
  fi
} | $sqlite $out >/dev/null

[[ -f $out-wal ]] || echo "warning: $out has no -wal file; the app opens it only after a writer does"
echo "fixture $out: $($sqlite -readonly $out "SELECT (SELECT COUNT(*) FROM traces) || ' traces, ' || (SELECT COUNT(*) FROM spans) || ' spans, ' || (SELECT COUNT(*) FROM logs) || ' logs, ' || (SELECT COUNT(*) FROM services) || ' services'")"
