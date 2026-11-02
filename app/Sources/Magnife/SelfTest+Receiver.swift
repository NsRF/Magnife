import Foundation
import MagnifeKit

/// Receiver checks (S-001, S-002) with the real bundled helper, started the
/// way the app starts it (AppModel.startReceiver), on free ports and fresh
/// databases in /tmp. Never 4317/4318, never the real database.
extension SelfTest {
    private static let receiverRoot = URL(fileURLWithPath: "/tmp/Magnife-selftest-receiver")

    static func checkReceiver() async {
        try? FileManager.default.removeItem(at: receiverRoot)
        guard let helper = AppModel.helperExecutable(environment: [:]),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            check("the bundled helper exists", false, "build with ./build.sh")
            return
        }
        await checkLaunch(helper)
        await checkHTTPBusy(helper)
        await checkWildcardGRPCBusy(helper)
        await checkBothBusy(helper)
        await checkQuietStart()
        try? FileManager.default.removeItem(at: receiverRoot)
    }

    /// S-001: HTTP within 1 s of launch, loopback only; S-002: gRPC export stored.
    private static func checkLaunch(_ helper: URL) async {
        let model = AppModel(storeURL: receiverRoot.appending(path: "launch/magnife.sqlite"))
        let ports = (grpc: freePort(), http: freePort())
        let launched = Date()
        model.startReceiver(executable: helper, ports: ports)
        let listening = await waitUntil(3) { model.receiver.isReceiving }
        let emptyBefore = model.showsEmptyState
        let traces = await post(port: ports.http, path: "/v1/traces", body: ReceiverPayload.trace)
        let logs = await post(port: ports.http, path: "/v1/logs", body: ReceiverPayload.log)
        let elapsed = Date().timeIntervalSince(launched)
        check("within 1 s of launch the helper accepts POST /v1/traces and /v1/logs with 200",
              listening && traces == 200 && logs == 200 && elapsed < 1,
              "listening \(listening), traces \(traces), logs \(logs), \(String(format: "%.2f", elapsed)) s")
        check("the toolbar reads \"Receiving on <gRPC> and <HTTP>\"",
              model.receiverStatusText == "Receiving on \(ports.grpc) and \(ports.http)", model.receiverStatusText ?? "nil")
        check("no busy-port banner while both ports listen", model.receiver.busyBanner == nil)
        let shown = await waitUntil(2) { model.traces.contains { $0.route == ReceiverPayload.route } }
        check("the trace posted over HTTP reaches the list", shown, "\(model.traces.map(\.route))")
        check("the empty state goes away once the first trace arrives (S-003)",
              emptyBefore && !model.showsEmptyState, "before \(emptyBefore), after \(model.showsEmptyState)")
        check("the variables name the port the helper reported (S-003)", model.environmentHTTPPort == ports.http)

        let sockets = listeningSockets(pid: model.helperPID)
        check("the helper listens only on 127.0.0.1 (no firewall prompt)",
              sockets.count == 2 && sockets.allSatisfy { $0.hasPrefix("127.0.0.1:") }, "\(sockets)")
        let refused = await run(helper, ["--db", receiverRoot.appending(path: "refused/magnife.sqlite").path,
                                         "--http", "0.0.0.0:\(freePort())", "--grpc", "127.0.0.1:\(freePort())", "--no-stdin"])
        check("the helper refuses a non-loopback address", refused.status != 0, "exit \(refused.status)")

        // S-002: a real OTLP/gRPC exporter (the sample sender) sends traces and logs to the gRPC port.
        if let sender = ProcessInfo.processInfo.environment["APP_SAMPLE_SENDER"].map(URL.init(fileURLWithPath:)) {
            let sent = await run(sender, ["--protocol", "grpc", "--scenarios", "healthy,logs",
                                          "--grpc", "127.0.0.1:\(ports.grpc)", "--http", "127.0.0.1:\(ports.http)"])
            check("an OTLP/gRPC export of traces and logs succeeds", sent.status == 0, sent.output)
            let stored = await waitUntil(2) { model.traces.contains { $0.route == "GET /checkout" } }
            let trace = model.traces.first { $0.route == "GET /checkout" }
            let spans = (try? await model.reader?.spans(traceID: trace?.traceID ?? "")) ?? []
            let received = (try? await model.reader?.latestLogs())?.filter { $0.serviceName != ReceiverPayload.service } ?? []
            check("the gRPC spans and logs are stored", stored && spans.count == 12 && received.count == 12,
                  "trace \(stored), \(spans.count) spans, \(received.count) logs")
        } else {
            check("APP_SAMPLE_SENDER names the sample sender (tools/selftest.sh)", false)
        }
        await model.stopHelperAndWait()
        check("stopping the receiver frees its ports", portIsFree(ports.http) && portIsFree(ports.grpc))
    }

    /// S-001: another app on the HTTP port shows the banner with its name; Try Again binds it once free.
    private static func checkHTTPBusy(_ helper: URL) async {
        guard let holder = PortHolder(address: "127.0.0.1") else { return check("hold a port", false) }
        let model = AppModel(storeURL: receiverRoot.appending(path: "http-busy/magnife.sqlite"))
        let ports = (grpc: freePort(), http: holder.port)
        model.startReceiver(executable: helper, ports: ports)
        _ = await waitUntil(3) { model.receiver != .starting }
        let owner = ProcessInfo.processInfo.processName
        check("a busy HTTP port reads \"Receiving on <gRPC> only\"",
              model.receiverStatusText == "Receiving on \(ports.grpc) only", model.receiverStatusText ?? "nil")
        check("the banner names the busy port and the app holding it",
              model.receiver.busyBanner == "Port \(ports.http) is in use by \(owner). Quit that app, then click Try Again.",
              model.receiver.busyBanner ?? "nil")
        holder.close()
        model.retryPorts()
        let bound = await waitUntil(3) { model.receiver.busyPorts.isEmpty && model.receiver.isReceiving }
        check("Try Again binds the port once it is free and the banner goes away",
              bound && model.receiver.busyBanner == nil, model.receiverStatusText ?? "nil")
        check("then HTTP accepts traces", await post(port: ports.http, path: "/v1/traces", body: ReceiverPayload.trace) == 200)
        await model.stopHelperAndWait()
    }

    /// S-001 / S-002: a collector on *:gRPC (any address) is reported busy; HTTP keeps working.
    private static func checkWildcardGRPCBusy(_ helper: URL) async {
        guard let holder = PortHolder(address: "0.0.0.0") else { return check("hold a wildcard port", false) }
        defer { holder.close() }
        let model = AppModel(storeURL: receiverRoot.appending(path: "grpc-busy/magnife.sqlite"))
        let ports = (grpc: holder.port, http: freePort())
        model.startReceiver(executable: helper, ports: ports)
        _ = await waitUntil(3) { model.receiver != .starting }
        check("a listener on *:<gRPC> shows the busy-port banner instead of binding alongside it",
              model.receiver.busyBanner?.hasPrefix("Port \(ports.grpc) is in use by ") == true
                && !listeningSockets(pid: model.helperPID).contains("127.0.0.1:\(ports.grpc)"),
              model.receiver.busyBanner ?? "nil")
        check("a busy gRPC port reads \"Receiving on <HTTP> only\"",
              model.receiverStatusText == "Receiving on \(ports.http) only", model.receiverStatusText ?? "nil")
        check("with gRPC busy, HTTP keeps working",
              await post(port: ports.http, path: "/v1/traces", body: ReceiverPayload.trace) == 200)
        await model.stopHelperAndWait()
    }

    /// S-002: both ports busy reads "Not receiving" with one banner naming both.
    private static func checkBothBusy(_ helper: URL) async {
        guard let grpc = PortHolder(address: "127.0.0.1"), let http = PortHolder(address: "0.0.0.0") else {
            return check("hold two ports", false)
        }
        defer { grpc.close(); http.close() }
        let model = AppModel(storeURL: receiverRoot.appending(path: "both-busy/magnife.sqlite"))
        model.startReceiver(executable: helper, ports: (grpc.port, http.port))
        _ = await waitUntil(3) { model.receiver != .starting }
        check("both ports busy reads \"Not receiving\"", model.receiverStatusText == "Not receiving", model.receiverStatusText ?? "nil")
        check("one banner names both ports",
              model.receiver.busyBanner == "Ports \(grpc.port) and \(http.port) are in use by other apps. Quit them, then click Try Again.",
              model.receiver.busyBanner ?? "nil")
        await model.stopHelperAndWait()
    }

    /// S-001: a start shows nothing for half a second, then "Starting receiver…".
    /// The helper here never reports its ports; it reads stdin until EOF.
    private static func checkQuietStart() async {
        let silent = receiverRoot.appending(path: "silent-helper")
        try? FileManager.default.createDirectory(at: receiverRoot, withIntermediateDirectories: true)
        try? "#!/bin/sh\nexec cat > /dev/null\n".write(to: silent, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: silent.path)
        let model = AppModel(storeURL: receiverRoot.appending(path: "silent/magnife.sqlite"))
        model.startReceiver(executable: silent, ports: (freePort(), freePort()))
        try? await Task.sleep(for: .seconds(0.25))
        check("a quick start shows no status", model.receiverStatusText == nil, model.receiverStatusText ?? "nil")
        try? await Task.sleep(for: .seconds(0.45))
        check("after half a second the toolbar reads \"Starting receiver…\"",
              model.receiverStatusText == "Starting receiver…", model.receiverStatusText ?? "nil")
        model.handle(.helper(.error(message: "open database: disk I/O error")))
        check("a helper error line shows as a receiver problem with Try Again",
              model.helperProblem == "The receiver reported a problem: open database: disk I/O error")
        model.retryPorts()
        check("Try Again clears the problem", model.helperProblem == nil)
        await model.stopHelperAndWait()
    }

    // MARK: Tools

    /// Polls `condition` every 20 ms for up to `seconds`.
    private static func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// POSTs OTLP/JSON to 127.0.0.1; the status code, or 0 when the request failed.
    private static func post(port: Int, path: String, body: String) async -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let response = try? await session.data(for: request).1 as? HTTPURLResponse
        return response?.statusCode ?? 0
    }

    /// A port nobody listens on right now.
    private static func freePort() -> Int {
        guard let holder = PortHolder(address: "127.0.0.1") else { return 0 }
        defer { holder.close() }
        return holder.port
    }

    private static func portIsFree(_ port: Int) -> Bool {
        guard let holder = PortHolder(address: "127.0.0.1", port: port) else { return false }
        holder.close()
        return true
    }

    /// The TCP addresses a process listens on, from lsof ("127.0.0.1:51234").
    private static func listeningSockets(pid: Int32?) -> [String] {
        guard let pid else { return [] }
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        lsof.waitUntilExit()
        return output.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }

    /// Runs a program to its end off the main actor; its exit status and stderr.
    private static func run(_ executable: URL, _ arguments: [String]) async -> (status: Int32, output: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return (-1, "could not run \(executable.path)") }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }
}

/// Minimal OTLP/JSON bodies for the receiver checks.
private enum ReceiverPayload {
    static let service = "selftest"
    static let route = "GET /selftest"

    static var trace: String {
        let start = UInt64(Date().timeIntervalSince1970 * 1e9)
        return """
        {"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"\(service)"}}]},
        "scopeSpans":[{"spans":[{"traceId":"5e1f7e57000000000000000000000001","spanId":"5e1f7e5700000001",
        "name":"\(route)","kind":2,"startTimeUnixNano":"\(start)","endTimeUnixNano":"\(start + 12_000_000)"}]}]}]}
        """
    }

    static var log: String {
        """
        {"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"\(service)"}}]},
        "scopeLogs":[{"logRecords":[{"timeUnixNano":"\(UInt64(Date().timeIntervalSince1970 * 1e9))",
        "severityNumber":9,"severityText":"INFO","body":{"stringValue":"self-test"}}]}]}]}
        """
    }
}

/// Holds a TCP port open, as another collector would (SO_REUSEADDR, like Go
/// and most servers). Port 0 picks a free one. The wildcard holder needs no
/// firewall prompt here (firewall off); with the firewall on, macOS may ask once.
nonisolated final class PortHolder {
    let port: Int
    private var socket: Int32

    init?(address: String, port: Int = 0) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, address, &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            return nil
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.port = Int(UInt16(bigEndian: addr.sin_port))
        socket = fd
    }

    func close() {
        guard socket >= 0 else { return }
        Darwin.close(socket)
        socket = -1
    }

    deinit { close() }
}
