import Foundation
import Testing
@testable import MagnifeKit

@Suite("Environment variables (S-003)")
struct EnvironmentLanguageTests {
    @Test("the tabs, in order, with the glossary's titles")
    func tabs() {
        #expect(EnvironmentLanguage.allCases.map(\.title) == [".NET", "Go", "Node", "Python", "Java"])
        #expect(EnvironmentLanguage.defaultLanguage == .dotnet)
    }

    @Test("every language sets the service name, the HTTP endpoint and http/protobuf", arguments: EnvironmentLanguage.allCases)
    func common(language: EnvironmentLanguage) {
        let lines = language.text(httpPort: 4318).split(separator: "\n").map(String.init)
        #expect(Array(lines.prefix(3)) == [
            "export OTEL_SERVICE_NAME=my-service",
            "export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318",
            "export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf",
        ])
        #expect(!language.note.isEmpty)
    }

    @Test("Python also turns on logging auto-instrumentation; the others add nothing")
    func python() {
        #expect(EnvironmentLanguage.python.variables(httpPort: 4318).last?.name
            == "OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED")
        #expect(EnvironmentLanguage.python.text(httpPort: 4318)
            .hasSuffix("\nexport OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true"))
        #expect(EnvironmentLanguage.python.note.contains("opentelemetry-instrument"))
        for language in EnvironmentLanguage.allCases where language != .python {
            #expect(language.variables(httpPort: 4318).count == 3)
        }
    }

    @Test("the endpoint uses the receiver's HTTP port, not a fixed 4318")
    func port() {
        let text = EnvironmentLanguage.go.text(httpPort: 41_018)
        #expect(text.contains("http://localhost:41018\n"))
        #expect(!text.contains("4318"))
    }

    @Test("the text has no trailing newline and nothing a shell would misread")
    func pasteable() {
        for language in EnvironmentLanguage.allCases {
            let text = language.text(httpPort: 4318)
            #expect(!text.hasSuffix("\n"))
            for (name, value) in language.variables(httpPort: 4318) {
                #expect(!(name + value).contains { "<>|;&$`\"' ".contains($0) })
            }
        }
    }

    @Test("the last chosen tab is remembered, .NET the first time")
    func remembered() throws {
        let suite = "magnife-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(EnvironmentLanguage.stored(in: defaults) == .dotnet)
        EnvironmentLanguage.python.store(in: defaults)
        #expect(EnvironmentLanguage.stored(in: defaults) == .python)
        defaults.set("cobol", forKey: EnvironmentLanguage.defaultsKey)
        #expect(EnvironmentLanguage.stored(in: defaults) == .dotnet)
    }
}
