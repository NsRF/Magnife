import Foundation
import Testing
@testable import MagnifeKit

@Suite("Helper protocol")
struct HelperProtocolTests {
    @Test("ports line, with a busy port and its owner")
    func ports() throws {
        let line = #"{"type":"ports","grpc":{"addr":"127.0.0.1:4317","state":"listening"},"http":{"addr":"127.0.0.1:4318","state":"busy","owner":"otelcol-contrib","pid":4242}}"#
        guard case .ports(let ports) = try HelperEvent.decode(line: line) else { Issue.record("not ports"); return }
        #expect(ports.grpc == PortStatus(addr: "127.0.0.1:4317", state: .listening))
        #expect(ports.http.state == .busy)
        #expect(ports.http.owner == "otelcol-contrib")
        #expect(ports.http.pid == 4242)
        #expect(ports.http.port == 4318)
    }

    @Test("batch, pruned, and error lines")
    func otherEvents() throws {
        let batch = #"{"type":"batch","seq":42,"spans":120,"logs":30,"traces":["a","b"],"error_traces":["b"]}"#
        #expect(try HelperEvent.decode(line: batch)
                == .batch(BatchEvent(seq: 42, spans: 120, logs: 30, traces: ["a", "b"], errorTraces: ["b"])))
        #expect(try HelperEvent.decode(line: #"{"type":"batch","seq":1}"#) == .batch(BatchEvent(seq: 1, spans: 0, logs: 0)))
        #expect(try HelperEvent.decode(line: #"{"type":"pruned","traces":12,"spans":340,"logs":56}"#)
                == .pruned(PrunedEvent(traces: 12, spans: 340, logs: 56)))
        #expect(try HelperEvent.decode(line: #"{"type":"error","message":"database is locked"}"#)
                == .error(message: "database is locked"))
    }

    @Test("unknown types and unknown fields are not errors")
    func unknown() throws {
        #expect(try HelperEvent.decode(line: #"{"type":"metrics","n":1}"#) == .unknown(type: "metrics"))
        let line = #"{"type":"pruned","traces":1,"spans":2,"logs":3,"took_ms":9}"#
        #expect(try HelperEvent.decode(line: line) == .pruned(PrunedEvent(traces: 1, spans: 2, logs: 3)))
        let state = #"{"type":"ports","grpc":{"addr":"127.0.0.1:4317","state":"starting"},"http":{"addr":"127.0.0.1:4318","state":"listening"}}"#
        guard case .ports(let ports) = try HelperEvent.decode(line: state) else { Issue.record("not ports"); return }
        #expect(ports.grpc.state == .other("starting"))
        #expect(!ports.grpc.isListening)
    }

    @Test("malformed lines are reported", arguments: ["not json", "{", #"{"seq":1}"#, #"{"type":"batch"}"#, "[]"])
    func malformed(line: String) {
        guard case .malformed(let text, _) = HelperLine(line) else {
            Issue.record("\(line) decoded")
            return
        }
        #expect(text == line)
    }

    /// The example lines in docs/schema.sql ("Helper protocol"), each checked
    /// against the file byte for byte, then decoded.
    @Test("the contract's example lines decode")
    func contractExamples() throws {
        func fromDoc(_ fragments: [String]) -> String {
            for fragment in fragments { #expect(Schema.sql.contains("-- " + fragment), "not in schema.sql: \(fragment)") }
            return fragments.map { $0.trimmingCharacters(in: .whitespaces) }.joined()
        }
        let ports = fromDoc([
            #"  {"type":"ports","grpc":{"addr":"127.0.0.1:4317","state":"listening"},"#,
            #"                  "http":{"addr":"127.0.0.1:4318","state":"busy","#,
            #"                          "owner":"otelcol-contrib","pid":4242}}"#,
        ])
        #expect(try HelperEvent.decode(line: ports) == .ports(ReceiverPorts(
            grpc: PortStatus(addr: "127.0.0.1:4317", state: .listening),
            http: PortStatus(addr: "127.0.0.1:4318", state: .busy, owner: "otelcol-contrib", pid: 4242))))

        let batch = fromDoc([
            #"  {"type":"batch","seq":42,"spans":120,"logs":30,"#,
            #"   "traces":["<trace id>", ...],"error_traces":["<trace id>", ...]}"#,
        ]).replacingOccurrences(of: #""<trace id>", ..."#, with: #""4bf92f3577b34da6a3ce929d0e0e4736""#)
        #expect(try HelperEvent.decode(line: batch) == .batch(BatchEvent(
            seq: 42, spans: 120, logs: 30, traces: ["4bf92f3577b34da6a3ce929d0e0e4736"],
            errorTraces: ["4bf92f3577b34da6a3ce929d0e0e4736"])))

        let pruned = fromDoc([#"  {"type":"pruned","traces":12,"spans":340,"logs":56}"#])
        #expect(try HelperEvent.decode(line: pruned) == .pruned(PrunedEvent(traces: 12, spans: 340, logs: 56)))
        let error = fromDoc([#"  {"type":"error","message":"..."}"#])
        #expect(try HelperEvent.decode(line: error) == .error(message: "..."))

        let imported = fromDoc([
            #"  {"type":"imported","path":"/Users/me/checkout.otlp.jsonl","spans":12,"logs":3,"#,
            #"   "traces":["<trace id>", ...]}"#,
        ]).replacingOccurrences(of: #""<trace id>", ..."#, with: #""4bf92f3577b34da6a3ce929d0e0e4736""#)
        #expect(try HelperEvent.decode(line: imported) == .imported(ImportedEvent(
            path: "/Users/me/checkout.otlp.jsonl", spans: 12, logs: 3, traces: ["4bf92f3577b34da6a3ce929d0e0e4736"])))
        let importFailed = fromDoc([#"  {"type":"import_failed","path":"/Users/me/notes.txt","message":"..."}"#])
        #expect(try HelperEvent.decode(line: importFailed) == .importFailed(path: "/Users/me/notes.txt", message: "..."))

        // stdin commands and launch flags, as the contract spells them.
        for command in ["retention <seconds>", "prune", "retry", "import <path>"] { #expect(Schema.sql.contains("--   " + command)) }
        #expect(HelperCommand.retention(seconds: 60).line == "retention 60")
        #expect(Schema.sql.contains("Contents/Helpers/magnife-ingest --db <path> --grpc 127.0.0.1:4317"))
        #expect(Schema.sql.contains("--http 127.0.0.1:4318 --retention <seconds>"))
    }

    /// What the Go helper really prints (ingest/internal/helper/protocol.go):
    /// owner and pid are omitted when unknown, and a batch with no spans
    /// encodes its empty lists as null.
    @Test("the Go helper's own encodings")
    func goEncodings() throws {
        var buffer = LineBuffer()
        let lines = buffer.append(Data((
            #"{"type":"ports","grpc":{"addr":"127.0.0.1:34417","state":"listening"},"http":{"addr":"127.0.0.1:34418","state":"busy"}}"#
            + "\n" + #"{"type":"batch","seq":7,"spans":0,"logs":3,"traces":null,"error_traces":null}"# + "\n").utf8))
        #expect(lines.map(HelperLine.init) == [
            .event(.ports(ReceiverPorts(grpc: PortStatus(addr: "127.0.0.1:34417", state: .listening),
                                        http: PortStatus(addr: "127.0.0.1:34418", state: .busy)))),
            .event(.batch(BatchEvent(seq: 7, spans: 0, logs: 3))),
        ])
        let busy = ReceiverStatus.ports(ReceiverPorts(grpc: PortStatus(addr: "127.0.0.1:34417", state: .listening),
                                                      http: PortStatus(addr: "127.0.0.1:34418", state: .busy)))
        #expect(busy.text == "Receiving on 34417 only")
        #expect(busy.busyPorts.first?.owner == nil)
    }

    @Test("import paths are absolute, on one line, and fit the helper's command limit")
    func importPaths() {
        #expect(HelperCommand.isValidImportPath("/Users/me/My Traces/checkout 4bf92f35.jsonl"))
        #expect(!HelperCommand.isValidImportPath("relative/file.jsonl"))
        #expect(!HelperCommand.isValidImportPath("/Users/me/two\nlines.jsonl"))
        #expect(!HelperCommand.isValidImportPath("/" + String(repeating: "a", count: 4000)))
    }

    @Test("the Go helper's import lines, an empty trace list included")
    func goImportEncodings() throws {
        #expect(try HelperEvent.decode(line: #"{"type":"imported","path":"/tmp/logs.jsonl","spans":0,"logs":4,"traces":[]}"#)
                == .imported(ImportedEvent(path: "/tmp/logs.jsonl", spans: 0, logs: 4, traces: [])))
        #expect(try HelperEvent.decode(line: #"{"type":"import_failed","path":"/tmp/x","message":"The file is empty."}"#)
                == .importFailed(path: "/tmp/x", message: "The file is empty."))
    }

    @Test("commands are single lines")
    func commands() {
        #expect(HelperCommand.retention(seconds: 3600).line == "retention 3600")
        #expect(HelperCommand.prune.line == "prune")
        #expect(HelperCommand.importFile(path: "/Users/me/My Traces/a b.jsonl").line == "import /Users/me/My Traces/a b.jsonl")
        #expect(HelperCommand.retry.line == "retry")
    }

    @Test("receiver status words")
    func receiverStatus() {
        func ports(_ grpc: PortStatus.State, _ http: PortStatus.State) -> ReceiverStatus {
            .ports(ReceiverPorts(grpc: PortStatus(addr: "127.0.0.1:4317", state: grpc),
                                 http: PortStatus(addr: "127.0.0.1:4318", state: http)))
        }
        #expect(ports(.listening, .listening).text == "Receiving on 4317 and 4318")
        #expect(ports(.busy, .listening).text == "Receiving on 4318 only")
        #expect(ports(.listening, .busy).text == "Receiving on 4317 only")
        #expect(ports(.busy, .busy).text == "Not receiving")
        #expect(ports(.busy, .busy).busyPorts.count == 2)
        #expect(!ports(.busy, .busy).isReceiving)
        #expect(ReceiverStatus.starting.text == "Starting receiver…")
        #expect(ReceiverStatus.stopped("x").text == "Not receiving")
        let custom = ReceiverStatus.ports(ReceiverPorts(grpc: PortStatus(addr: "127.0.0.1:14317", state: .listening),
                                                        http: PortStatus(addr: "127.0.0.1:14318", state: .listening)))
        #expect(custom.text == "Receiving on 14317 and 14318")
    }
}

@Suite("LineBuffer")
struct LineBufferTests {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    @Test("a line split across chunks")
    func partial() {
        var buffer = LineBuffer()
        #expect(buffer.append(data(#"{"type":"bat"#)).isEmpty)
        #expect(buffer.append(data(#"ch","seq":1}"#)).isEmpty)
        #expect(buffer.append(data("\n")) == [#"{"type":"batch","seq":1}"#])
    }

    @Test("several lines in one chunk, the last one partial")
    func several() {
        var buffer = LineBuffer()
        #expect(buffer.append(data("a\nb\nc")) == ["a", "b"])
        #expect(buffer.append(data("d\n")) == ["cd"])
    }

    @Test("CRLF and empty lines")
    func crlf() {
        var buffer = LineBuffer()
        #expect(buffer.append(data("a\r\n\r\n\nb\r")) == ["a"])
        #expect(buffer.append(data("\n")) == ["b"])
    }

    @Test("a multi-byte character split between chunks")
    func utf8() {
        var buffer = LineBuffer()
        let bytes = Array("µs\n".utf8)
        #expect(buffer.append(Data(bytes[0..<1])).isEmpty)
        #expect(buffer.append(Data(bytes[1...])) == ["µs"])
    }

    @Test("finish returns the last line with no line break")
    func finish() {
        var buffer = LineBuffer()
        #expect(buffer.append(data("a\nlast")) == ["a"])
        #expect(buffer.finish() == ["last"])
        #expect(buffer.finish().isEmpty)
    }

    @Test("an endless line is dropped, and the next line still reads")
    func tooLong() {
        var buffer = LineBuffer(maxLineLength: 8)
        #expect(buffer.append(data("0123456789")).isEmpty)
        #expect(buffer.append(data("\nok\n")) == ["ok"])
    }

    @Test("malformed JSON between good lines")
    func mixed() {
        var buffer = LineBuffer()
        let lines = buffer.append(data(#"{"type":"error","message":"m"}"# + "\nnope\n" + #"{"type":"x"}"# + "\n"))
        #expect(lines.map(HelperLine.init) == [
            .event(.error(message: "m")),
            HelperLine("nope"),
            .event(.unknown(type: "x")),
        ])
    }
}

@Suite("RestartBackoff")
struct RestartBackoffTests {
    @Test("doubles from 0.5 s to 30 s")
    func doubles() {
        var backoff = RestartBackoff()
        let delays = (0..<9).map { _ in backoff.delay(afterRunOf: 1) }
        #expect(delays == [0.5, 1, 2, 4, 8, 16, 30, 30, 30])
    }

    @Test("a run of 60 s resets the wait")
    func resets() {
        var backoff = RestartBackoff()
        _ = backoff.delay(afterRunOf: 1)
        _ = backoff.delay(afterRunOf: 1)
        #expect(backoff.delay(afterRunOf: 59) == 2)
        #expect(backoff.delay(afterRunOf: 60) == 0.5)
        #expect(backoff.delay(afterRunOf: 1) == 1)
    }
}
