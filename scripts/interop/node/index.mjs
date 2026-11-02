// Sends one trace, two logs and a metric with @opentelemetry/sdk-node,
// configured only by the standard OTEL_* environment variables
// (OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_EXPORTER_OTLP_PROTOCOL, OTEL_SERVICE_NAME).
//
// Prints one JSON line with the ids it sent and exits 1 if the SDK reported
// any export error, so scripts/interop/run-all.sh can check the database.
import { NodeSDK } from "@opentelemetry/sdk-node";
import { diag, DiagLogLevel, logs, metrics, SeverityNumber, SpanKind, SpanStatusCode, trace, context } from "@opentelemetry/api";

const sdk = new NodeSDK();
sdk.start();

// Installed after start, so it replaces the SDK's console logger. Export
// failures reach diag.error through the SDK's global error handler.
const problems = [];
const record = (level) => (...args) => {
  const text = args.map((a) => (a instanceof Error ? a.stack : typeof a === "string" ? a : JSON.stringify(a))).join(" ");
  problems.push(`${level}: ${text}`);
  console.error(`otel ${level}: ${text}`);
};
diag.setLogger(
  { error: record("error"), warn: record("warn"), info() {}, debug() {}, verbose() {} },
  { logLevel: DiagLogLevel.WARN, suppressOverrideMessage: true },
);

const tracer = trace.getTracer("magnife-interop");
const logger = logs.getLogger("magnife-interop");
const counter = metrics.getMeter("magnife-interop").createCounter("interop.requests");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const ids = {};
await tracer.startActiveSpan(
  "GET /orders/{id}",
  {
    kind: SpanKind.SERVER,
    attributes: {
      "http.request.method": "GET",
      "http.route": "/orders/{id}",
      "url.path": "/orders/42",
      "http.response.status_code": 200,
    },
  },
  async (root) => {
    ids.trace_id = root.spanContext().traceId;
    ids.root_span_id = root.spanContext().spanId;
    await tracer.startActiveSpan(
      "SELECT orders",
      {
        kind: SpanKind.CLIENT,
        attributes: { "db.system.name": "postgresql", "db.query.text": "SELECT * FROM orders WHERE id = $1" },
      },
      async (db) => {
        ids.db_span_id = db.spanContext().spanId;
        // The active context carries the span, so the record gets its ids.
        logger.emit({
          severityNumber: SeverityNumber.INFO,
          severityText: "INFO",
          body: "loading order 42",
          attributes: { "interop.sdk": "node" },
        });
        await sleep(5);
        db.end();
      },
    );
    const call = tracer.startSpan("POST", {
      kind: SpanKind.CLIENT,
      attributes: {
        "http.request.method": "POST",
        "url.full": "http://payments.local/charge",
        "http.response.status_code": 500,
      },
    });
    ids.call_span_id = call.spanContext().spanId;
    call.recordException(new Error("payment service returned 500"));
    call.setStatus({ code: SpanStatusCode.ERROR, message: "HTTP 500" });
    call.end();
    counter.add(1);
    root.end();
  },
);
context.with(trace.deleteSpan(context.active()), () => {
  logger.emit({
    severityNumber: SeverityNumber.WARN,
    severityText: "WARN",
    body: "interop run finished",
    attributes: { "interop.sdk": "node" },
  });
});

// shutdown flushes traces, logs and metrics.
try {
  await sdk.shutdown();
} catch (err) {
  record("error")(err);
}
console.log(JSON.stringify(ids));
process.exit(problems.length > 0 ? 1 : 0);
