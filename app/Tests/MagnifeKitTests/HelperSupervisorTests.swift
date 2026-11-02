import Foundation
import Testing
@testable import MagnifeKit

/// HelperSupervisor against FakeHelper, a zsh script that speaks the protocol.
@Suite("HelperSupervisor", .serialized)
struct HelperSupervisorTests {
    private func configuration(_ dir: TempDir, environment: [String: String] = [:],
                               stopTimeout: TimeInterval = 3) throws -> HelperConfiguration {
        HelperConfiguration(executableURL: try FakeHelper.write(to: dir.url),
                            databaseURL: dir.file("magnife.sqlite"),
                            grpcPort: 14317, httpPort: 14318, retentionSeconds: 3600,
                            backoff: RestartBackoff(initial: 0.1, maximum: 0.4, stableAfter: 60),
                            stopTimeout: stopTimeout, environment: environment)
    }

    @Test("passes the contract's flags")
    func flags() throws {
        let dir = try TempDir("supervisor-flags")
        defer { dir.remove() }
        let config = try configuration(dir)
        #expect(config.arguments == ["--db", dir.file("magnife.sqlite").path, "--grpc", "127.0.0.1:14317",
                                     "--http", "127.0.0.1:14318", "--retention", "3600"])
        #expect(HelperConfiguration.ports(environment: [:]) == (4317, 4318))
        #expect(HelperConfiguration.ports(environment: ["APP_GRPC_PORT": "5317", "APP_HTTP_PORT": "5318"]) == (5317, 5318))
        #expect(HelperConfiguration.ports(environment: ["APP_GRPC_PORT": "zero", "APP_HTTP_PORT": "70000"]) == (4317, 4318))
        #expect(HelperConfiguration.bundledExecutable(in: Bundle(path: "/Applications/Magnife.app") ?? .main)
                    .path.hasSuffix("Contents/Helpers/magnife-ingest"))
    }

    @Test("reads events, skips unknown types, reports malformed lines, answers commands")
    func events() async throws {
        let dir = try TempDir("supervisor-events")
        defer { dir.remove() }
        let supervisor = HelperSupervisor(configuration: try configuration(dir))
        var events = supervisor.events.makeAsyncIterator()
        supervisor.start()

        guard case .started(_, let restart) = await next(&events, where: { _ in true }) else {
            Issue.record("no start")
            return
        }
        #expect(!restart)
        let argv = await next(&events) { if case .helper(.error) = $0 { true } else { false } }
        #expect(argv == .helper(.error(message: "args: " + (try configuration(dir)).arguments.joined(separator: " "))))
        let ports = await next(&events) { if case .helper(.ports) = $0 { true } else { false } }
        guard case .helper(.ports(let receiver)) = ports else { Issue.record("no ports"); return }
        #expect(ReceiverStatus.ports(receiver).text == "Receiving on 4317 only")
        // The batch line arrives in two writes; the unknown "future" type never shows.
        #expect(await next(&events, where: { _ in true }) == .helper(.batch(BatchEvent(seq: 1, spans: 3, logs: 1, traces: ["t1"]))))
        #expect(await next(&events, where: { _ in true }) == .malformedLine("not json"))

        try supervisor.send(.retry)
        #expect(await next(&events, where: { _ in true }) == ports)
        try supervisor.send(.prune)
        #expect(await next(&events, where: { _ in true }) == .helper(.pruned(PrunedEvent(traces: 1, spans: 2, logs: 3))))
        try supervisor.send(.retention(seconds: 600))
        #expect(await next(&events, where: { _ in true }) == .helper(.error(message: "retention 600")))

        await supervisor.stop()
        #expect(await next(&events) { $0 == .stopped } == .stopped)
        #expect(supervisor.pid == nil)
        #expect(throws: HelperSupervisorError.notRunning) { try supervisor.send(.prune) }
    }

    @Test("restarts after a crash with backoff, and says so")
    func restarts() async throws {
        let dir = try TempDir("supervisor-crash")
        defer { dir.remove() }
        let supervisor = HelperSupervisor(configuration: try configuration(dir))
        var events = supervisor.events.makeAsyncIterator()
        supervisor.start()
        _ = await next(&events) { if case .helper(.ports) = $0 { true } else { false } }
        var delays: [TimeInterval] = []
        for round in 1...3 {
            let pid = try #require(supervisor.pid)
            kill(pid, SIGKILL)
            let crash = await next(&events) { if case .crashed = $0 { true } else { false } }
            guard case .crashed(let status, _) = crash else { Issue.record("no crash"); return }
            #expect(status == SIGKILL)
            guard case .restartScheduled(let delay) = await next(&events, where: { _ in true }) else {
                Issue.record("no restart")
                return
            }
            delays.append(delay)
            let started = await next(&events) { if case .started = $0 { true } else { false } }
            guard case .started(let newPid, let restart) = started else { Issue.record("round \(round)"); return }
            #expect(restart)
            #expect(newPid != pid)
            _ = await next(&events) { if case .helper(.ports) = $0 { true } else { false } }
        }
        #expect(delays == [0.1, 0.2, 0.4])
        await supervisor.stop()
    }

    @Test("a run that stayed up past stableAfter resets the wait")
    func backoffResets() async throws {
        let dir = try TempDir("supervisor-stable")
        defer { dir.remove() }
        var config = try configuration(dir)
        config.backoff = RestartBackoff(initial: 0.1, maximum: 0.4, stableAfter: 0.6)
        let supervisor = HelperSupervisor(configuration: config)
        var events = supervisor.events.makeAsyncIterator()
        supervisor.start()
        var delays: [TimeInterval] = []
        // Two quick crashes, then a run of about 1 s, then a quick one.
        for upFor in [0.0, 0.0, 1.0, 0.0] {
            _ = await next(&events) { if case .helper(.ports) = $0 { true } else { false } }
            if upFor > 0 { try await Task.sleep(for: .seconds(upFor)) }
            kill(try #require(supervisor.pid), SIGKILL)
            guard case .restartScheduled(let delay) = await next(&events, where: {
                if case .restartScheduled = $0 { true } else { false }
            }) else {
                Issue.record("no restart")
                return
            }
            delays.append(delay)
            _ = await next(&events) { if case .started = $0 { true } else { false } }
        }
        #expect(delays == [0.1, 0.2, 0.1, 0.2])
        await supervisor.stop()
    }

    @Test("a restart after a crash keeps the retention set since launch")
    func restartKeepsRetention() async throws {
        let dir = try TempDir("supervisor-retention")
        defer { dir.remove() }
        let supervisor = HelperSupervisor(configuration: try configuration(dir))
        var events = supervisor.events.makeAsyncIterator()
        supervisor.start()
        _ = await next(&events) { if case .helper(.ports) = $0 { true } else { false } }
        supervisor.setRetention(seconds: 604_800)
        #expect(await next(&events) { if case .helper(.error) = $0 { true } else { false } }
                    == .helper(.error(message: "retention 604800")))
        #expect(supervisor.launchArguments.suffix(2) == ["--retention", "604800"])

        kill(try #require(supervisor.pid), SIGKILL)
        _ = await next(&events) { if case .crashed = $0 { true } else { false } }
        // Set while the helper is down: the next launch passes it.
        supervisor.setRetention(seconds: 21_600)
        _ = await next(&events) { if case .started = $0 { true } else { false } }
        let argv = await next(&events) { if case .helper(.error) = $0 { true } else { false } }
        guard case .helper(.error(let message)) = argv else { Issue.record("no args"); return }
        #expect(message.hasSuffix("--retention 21600"))
        await supervisor.stop()
    }

    @Test("stop closes stdin and the helper exits on EOF")
    func stopOnEOF() async throws {
        let dir = try TempDir("supervisor-eof")
        defer { dir.remove() }
        let supervisor = HelperSupervisor(configuration: try configuration(dir))
        var events = supervisor.events.makeAsyncIterator()
        supervisor.start()
        _ = await next(&events) { if case .helper(.ports) = $0 { true } else { false } }
        let pid = try #require(supervisor.pid)
        // A later child process must not inherit the helper's stdin and keep it open.
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["5"]
        try other.run()
        defer { other.terminate() }
        let started = Date()
        supervisor.stopAndWait()
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(kill(pid, 0) != 0)
        #expect(await next(&events) { $0 == .stopped } == .stopped)
    }

    @Test("stop terminates a helper that ignores EOF after the timeout")
    func stopTimeout() async throws {
        let dir = try TempDir("supervisor-stubborn")
        defer { dir.remove() }
        let supervisor = HelperSupervisor(configuration: try configuration(dir, environment: ["FAKE_HELPER_IGNORE_EOF": "1"],
                                                                           stopTimeout: 0.5))
        var events = supervisor.events.makeAsyncIterator()
        supervisor.start()
        _ = await next(&events) { if case .helper(.ports) = $0 { true } else { false } }
        let pid = try #require(supervisor.pid)
        let started = Date()
        supervisor.stopAndWait()
        let took = Date().timeIntervalSince(started)
        #expect(took >= 0.5 && took < 2.5)
        #expect(kill(pid, 0) != 0)
        #expect(await next(&events) { $0 == .stopped } == .stopped)
    }

    @Test("a missing executable is a launch failure, not a restart loop")
    func missingExecutable() async throws {
        let dir = try TempDir("supervisor-missing")
        defer { dir.remove() }
        var config = try configuration(dir)
        config.executableURL = dir.file("no-such-helper")
        let supervisor = HelperSupervisor(configuration: config)
        var events = supervisor.events.makeAsyncIterator()
        supervisor.start()
        guard case .launchFailed = await next(&events, where: { _ in true }) else {
            Issue.record("expected launchFailed")
            return
        }
        #expect(supervisor.pid == nil)
        #expect(throws: HelperSupervisorError.notRunning) { try supervisor.send(.retry) }
    }
}
