"""Sends one trace, two logs and a metric with the OpenTelemetry Python SDK.

Run it under opentelemetry-instrument (from opentelemetry-distro), which
configures the SDK only from the standard OTEL_* environment variables:

    OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_EXPORTER_OTLP_PROTOCOL, OTEL_SERVICE_NAME,
    OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true (for logs)

Prints one JSON line with the ids it sent and exits 1 if the SDK logged any
warning or error, so scripts/interop/run-all.sh can check the database.
"""

import json
import logging
import os
import sys
import time

from opentelemetry import _logs, metrics, trace
from opentelemetry.trace import SpanKind, Status, StatusCode, format_span_id, format_trace_id


class Problems(logging.Handler):
    """Collects the SDK's own warnings; exporters log failures, never raise."""

    def __init__(self):
        super().__init__(logging.WARNING)
        self.records = []

    def emit(self, record):
        self.records.append(record)
        print(f"otel {record.levelname}: {record.name}: {record.getMessage()}", file=sys.stderr)


problems = Problems()
sdk_log = logging.getLogger("opentelemetry")
sdk_log.addHandler(problems)
sdk_log.propagate = False  # keep SDK diagnostics out of the exported logs

log = logging.getLogger("magnife-interop")
log.setLevel(logging.INFO)
tracer = trace.get_tracer("magnife-interop")
counter = metrics.get_meter("magnife-interop").create_counter("interop.requests")

ids = {}
with tracer.start_as_current_span(
    "GET /orders/{id}",
    kind=SpanKind.SERVER,
    attributes={
        "http.request.method": "GET",
        "http.route": "/orders/{id}",
        "url.path": "/orders/42",
        "http.response.status_code": 200,
    },
) as root:
    ids["trace_id"] = format_trace_id(root.get_span_context().trace_id)
    ids["root_span_id"] = format_span_id(root.get_span_context().span_id)
    with tracer.start_as_current_span(
        "SELECT orders",
        kind=SpanKind.CLIENT,
        attributes={"db.system.name": "postgresql", "db.query.text": "SELECT * FROM orders WHERE id = $1"},
    ) as db:
        ids["db_span_id"] = format_span_id(db.get_span_context().span_id)
        # The current span is the db span, so the record gets its ids.
        log.info("loading order 42", extra={"interop.sdk": "python"})
        time.sleep(0.005)
    with tracer.start_as_current_span(
        "POST",
        kind=SpanKind.CLIENT,
        attributes={
            "http.request.method": "POST",
            "url.full": "http://payments.local/charge",
            "http.response.status_code": 500,
        },
        record_exception=False,
        set_status_on_exception=False,
    ) as call:
        ids["call_span_id"] = format_span_id(call.get_span_context().span_id)
        try:
            raise ConnectionError("payment service returned 500")
        except ConnectionError as exc:
            call.record_exception(exc)
        call.set_status(Status(StatusCode.ERROR, "HTTP 500"))
    counter.add(1)
log.warning("interop run finished", extra={"interop.sdk": "python"})

# Shut down here, not at exit, so export failures are seen before the result.
for provider in (trace.get_tracer_provider(), _logs.get_logger_provider(), metrics.get_meter_provider()):
    shutdown = getattr(provider, "shutdown", None)
    if shutdown is None:
        problems.records.append(f"{type(provider).__name__}: the SDK is not configured; run under opentelemetry-instrument")
        print(problems.records[-1], file=sys.stderr)
        continue
    shutdown()

print(json.dumps(ids), flush=True)
sys.stderr.flush()
os._exit(1 if problems.records else 0)  # skip the SDK's second shutdown at exit
