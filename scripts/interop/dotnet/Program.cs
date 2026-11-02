// Sends one trace, two logs and a metric with the OpenTelemetry .NET SDK and
// OpenTelemetry.Exporter.OpenTelemetryProtocol, configured only by the
// standard OTEL_* environment variables (AddOtlpExporter() with no options
// reads OTEL_EXPORTER_OTLP_ENDPOINT and OTEL_EXPORTER_OTLP_PROTOCOL; the
// default resource reads OTEL_SERVICE_NAME).
//
// Prints one JSON line with the ids it sent and exits 1 if the SDK reported
// an error, or the exporter a warning, so scripts/interop/run-all.sh can
// check the database.
using System.Diagnostics;
using System.Diagnostics.Metrics;
using System.Diagnostics.Tracing;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using OpenTelemetry;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;

using var problems = new SdkProblems();

var source = new ActivitySource("magnife-interop");
var meter = new Meter("magnife-interop");
var counter = meter.CreateCounter<long>("interop.requests");

var tracerProvider = Sdk.CreateTracerProviderBuilder()
    .AddSource(source.Name)
    .AddOtlpExporter()
    .Build();
var meterProvider = Sdk.CreateMeterProviderBuilder()
    .AddMeter(meter.Name)
    .AddOtlpExporter()
    .Build();
var loggerFactory = LoggerFactory.Create(b => b.AddOpenTelemetry(o => o.AddOtlpExporter()));
var logger = loggerFactory.CreateLogger("magnife-interop");

var ids = new Dictionary<string, string>();
using (var root = source.StartActivity("GET /orders/{id}", ActivityKind.Server)!)
{
    root.SetTag("http.request.method", "GET");
    root.SetTag("http.route", "/orders/{id}");
    root.SetTag("url.path", "/orders/42");
    root.SetTag("http.response.status_code", 200);
    ids["trace_id"] = root.TraceId.ToHexString();
    ids["root_span_id"] = root.SpanId.ToHexString();

    using (var db = source.StartActivity("SELECT orders", ActivityKind.Client)!)
    {
        db.SetTag("db.system.name", "postgresql");
        db.SetTag("db.query.text", "SELECT * FROM orders WHERE id = $1");
        ids["db_span_id"] = db.SpanId.ToHexString();
        // Activity.Current is the db span, so the record gets its ids.
        logger.LogInformation("loading order {OrderId}", 42);
        Thread.Sleep(5);
    }

    using (var call = source.StartActivity("POST", ActivityKind.Client)!)
    {
        call.SetTag("http.request.method", "POST");
        call.SetTag("url.full", "http://payments.local/charge");
        call.SetTag("http.response.status_code", 500);
        ids["call_span_id"] = call.SpanId.ToHexString();
        call.AddException(new HttpRequestException("payment service returned 500"));
        call.SetStatus(ActivityStatusCode.Error, "HTTP 500");
    }
    counter.Add(1);
}
logger.LogWarning("interop run finished");

// Dispose flushes; exporters report failures through their EventSource.
tracerProvider.Dispose();
meterProvider.Dispose();
loggerFactory.Dispose();

Console.WriteLine(JsonSerializer.Serialize(ids));
return problems.Count > 0 ? 1 : 0;

// Collects problems from the SDK's EventSources (export failures are logged
// there, never thrown).
sealed class SdkProblems : EventListener
{
    int count;
    public int Count => count;

    protected override void OnEventSourceCreated(EventSource source)
    {
        if (source.Name.StartsWith("OpenTelemetry", StringComparison.Ordinal))
            EnableEvents(source, EventLevel.Warning);
    }

    protected override void OnEventWritten(EventWrittenEventArgs e)
    {
        // The SDK warns about meters it does not listen to; that is not a failure.
        var exporter = e.EventSource.Name.StartsWith("OpenTelemetry-Exporter", StringComparison.Ordinal);
        if (e.Level > (exporter ? EventLevel.Warning : EventLevel.Error)) return;
        Interlocked.Increment(ref count);
        var message = e.Message is null || e.Payload is null
            ? e.EventName
            : string.Format(e.Message, e.Payload.ToArray());
        Console.Error.WriteLine($"otel {e.Level}: {e.EventSource.Name}: {message}");
    }
}
