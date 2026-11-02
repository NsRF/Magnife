package sample

// The three services of the seed data (docs/STORIES.md, "Seed data").
// checkout-api and web use the new semantic conventions (http.request.method,
// http.response.status_code, url.*, db.system.name, db.query.text); orders
// uses the old ones (http.method, http.status_code, db.system, db.statement),
// so both spellings reach the helper.
var (
	CheckoutAPI = &Service{Name: "checkout-api", Resource: map[string]any{
		"service.name":            "checkout-api",
		"service.namespace":       "shop",
		"service.version":         "1.8.2",
		"service.instance.id":     "6f0c1a52-1d3e-4b8e-9a43-2f1d8f6c0b71",
		"deployment.environment":  "development",
		"telemetry.sdk.name":      "opentelemetry",
		"telemetry.sdk.language":  "dotnet",
		"telemetry.sdk.version":   "1.12.0",
		"process.runtime.name":    ".NET",
		"process.runtime.version": "9.0.10",
		"process.pid":             41873,
		"host.name":               "dev-mbp.local",
		"host.arch":               "arm64",
		"os.type":                 "darwin",
	}}
	Orders = &Service{Name: "orders", Resource: map[string]any{
		"service.name":                "orders",
		"service.namespace":           "shop",
		"service.version":             "0.14.0",
		"service.instance.id":         "orders-dev-mbp-41902",
		"deployment.environment":      "development",
		"telemetry.sdk.name":          "opentelemetry",
		"telemetry.sdk.language":      "go",
		"telemetry.sdk.version":       "1.38.0",
		"process.runtime.name":        "go",
		"process.runtime.version":     "go1.27.3",
		"process.runtime.description": "go version go1.27.3 darwin/arm64",
		"process.executable.name":     "orders",
		"process.pid":                 41902,
		"host.name":                   "dev-mbp.local",
		"host.arch":                   "arm64",
		"os.type":                     "darwin",
	}}
	Web = &Service{Name: "web", Resource: map[string]any{
		"service.name":                "web",
		"service.namespace":           "shop",
		"service.version":             "3.2.0",
		"service.instance.id":         "b8a4e1f2-73c5-4d0a-8f6e-0c9d2a7e5b13",
		"deployment.environment.name": "development",
		"telemetry.sdk.name":          "opentelemetry",
		"telemetry.sdk.language":      "nodejs",
		"telemetry.sdk.version":       "2.1.0",
		"process.runtime.name":        "nodejs",
		"process.runtime.version":     "22.20.0",
		"process.command":             "/Users/dev/shop/web/server.js",
		"process.pid":                 41766,
		"host.name":                   "dev-mbp.local",
		"host.arch":                   "arm64",
		"os.type":                     "darwin",
	}}
)

// Instrumentation scopes, as the real libraries name them.
var (
	scopeAspNetCore = Scope{"Microsoft.AspNetCore", ""}
	scopeHTTPClient = Scope{"System.Net.Http", ""}
	scopeGrpcNet    = Scope{"Grpc.Net.Client", ""}
	scopeEFCore     = Scope{"OpenTelemetry.Instrumentation.EntityFrameworkCore", "1.12.0-beta.2"}
	scopeNetLogs    = Scope{"Checkout.Api.Orders.OrderService", ""}
	scopeNetPay     = Scope{"Checkout.Api.Payments.PaymentService", ""}
	scopeNetDiag    = Scope{"Microsoft.AspNetCore.Diagnostics.DeveloperExceptionPageMiddleware", ""}
	scopeNetHosting = Scope{"Microsoft.Hosting.Lifetime", ""}
	scopeNetEFCmd   = Scope{"Microsoft.EntityFrameworkCore.Database.Command", ""}

	scopeOtelHTTP = Scope{"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp", "0.63.0"}
	scopeOtelGRPC = Scope{"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc", "0.63.0"}
	scopeOtelSQL  = Scope{"github.com/XSAM/otelsql", "0.40.0"}
	scopeGoJobs   = Scope{"orders/internal/jobs", ""}
	scopeGoSlog   = Scope{"go.opentelemetry.io/contrib/bridges/otelslog", "0.13.0"}

	scopeNodeHTTP    = Scope{"@opentelemetry/instrumentation-http", "0.205.0"}
	scopeNodeExpress = Scope{"@opentelemetry/instrumentation-express", "0.54.0"}
	scopeNodeUndici  = Scope{"@opentelemetry/instrumentation-undici", "0.16.0"}
	scopeNodePino    = Scope{"@opentelemetry/instrumentation-pino", "0.52.0"}
)
