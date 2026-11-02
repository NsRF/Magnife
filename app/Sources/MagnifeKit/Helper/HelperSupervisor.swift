import Foundation

/// What the supervisor reports, in order, on `events`.
public enum SupervisorEvent: Sendable, Equatable {
    /// The helper is running. `restart` is true after a crash (the S-008 banner).
    case started(pid: Int32, restart: Bool)
    /// A protocol line from the helper's stdout.
    case helper(HelperEvent)
    /// A stdout line that is not a protocol object. Reported, never fatal.
    case malformedLine(String)
    /// The helper ended without stop().
    case crashed(status: Int32, uptime: TimeInterval)
    case restartScheduled(delay: TimeInterval)
    /// The executable could not start; no retry, since a missing file stays missing.
    case launchFailed(String)
    /// The helper exited after stop().
    case stopped
}

public enum HelperSupervisorError: Error, Equatable {
    case notRunning
    case writeFailed(String)
}

/// Runs magnife-ingest as a child process: holds its stdin open (closing it
/// stops the helper, also when the app dies), turns its stdout into events,
/// passes its stderr through to the app's stderr, and restarts it after a
/// crash with backoff. Foundation only, so tests drive it with a fake helper.
public final class HelperSupervisor: @unchecked Sendable {
    public let events: AsyncStream<SupervisorEvent>
    public let configuration: HelperConfiguration

    private let continuation: AsyncStream<SupervisorEvent>.Continuation
    // Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "Magnife.helper-supervisor")
    private var process: Process?
    private var stdin: FileHandle?
    private var launchedAt = Date.distantPast
    private var backoff: RestartBackoff
    private var wanted = false
    private var restartWork: DispatchWorkItem?
    /// The retention every launch passes, the configuration's until setRetention.
    private var retentionSeconds: Int

    public init(configuration: HelperConfiguration) {
        self.configuration = configuration
        backoff = configuration.backoff
        retentionSeconds = configuration.retentionSeconds
        (events, continuation) = AsyncStream.makeStream(of: SupervisorEvent.self)
        // Writing to a helper that just died must fail with an error, not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    deinit {
        continuation.finish()
    }

    /// The helper's pid while it runs.
    public var pid: Int32? {
        queue.sync { process?.processIdentifier }
    }

    public func start() {
        queue.async {
            guard !self.wanted else { return }
            self.wanted = true
            self.backoff = self.configuration.backoff
            self.launch(restart: false)
        }
    }

    /// Writes one command line to the helper's stdin.
    public func send(_ command: HelperCommand) throws(HelperSupervisorError) {
        let result: Result<Void, HelperSupervisorError> = queue.sync {
            guard let stdin else { return .failure(.notRunning) }
            do {
                try stdin.write(contentsOf: Data((command.line + "\n").utf8))
                return .success(())
            } catch {
                return .failure(.writeFailed(String(describing: error)))
            }
        }
        try result.get()
    }

    /// Changes the retention: sent to a running helper at once, and passed
    /// as --retention to every later launch, so a restart after a crash or a
    /// change made while the helper is down keeps the chosen period (S-016).
    public func setRetention(seconds: Int) {
        queue.sync {
            retentionSeconds = seconds
            try? stdin?.write(contentsOf: Data((HelperCommand.retention(seconds: seconds).line + "\n").utf8))
        }
    }

    /// The arguments the next launch passes.
    public var launchArguments: [String] {
        queue.sync { launchConfiguration.arguments }
    }

    private var launchConfiguration: HelperConfiguration {
        var current = configuration
        current.retentionSeconds = retentionSeconds
        return current
    }

    /// Closes stdin, waits up to `stopTimeout` for the helper to exit, then
    /// terminates it. Blocks; applicationWillTerminate calls it so a relaunch
    /// can bind the ports at once (platform decision 6).
    public func stopAndWait() {
        let running: Process? = queue.sync {
            wanted = false
            restartWork?.cancel()
            restartWork = nil
            try? stdin?.close()
            stdin = nil
            return process
        }
        guard let running else { return }
        if !Self.wait(for: running, timeout: configuration.stopTimeout) {
            running.terminate()
            if !Self.wait(for: running, timeout: 2) {
                kill(running.processIdentifier, SIGKILL)
                running.waitUntilExit()
            }
        }
    }

    /// stopAndWait without blocking the caller.
    public func stop() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.stopAndWait()
                done.resume()
            }
        }
    }

    // MARK: On queue

    private func launch(restart: Bool) {
        guard wanted, process == nil else { return }
        let child = Process()
        child.executableURL = configuration.executableURL
        child.arguments = launchConfiguration.arguments
        child.environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { $1 }
        let input = Pipe()
        let output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.standardError

        let reader = StdoutReader()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            guard let self else { return }
            self.queue.async { self.receive(chunk, reader: reader) }
        }
        child.terminationHandler = { [weak self] ended in
            guard let self else { return }
            self.queue.async { self.exited(ended) }
        }
        do {
            try child.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            wanted = false
            continuation.yield(.launchFailed("\(configuration.executableURL.path): \(error.localizedDescription)"))
            return
        }
        process = child
        stdin = input.fileHandleForWriting
        launchedAt = Date()
        continuation.yield(.started(pid: child.processIdentifier, restart: restart))
    }

    private func receive(_ chunk: Data, reader: StdoutReader) {
        let lines = chunk.isEmpty ? reader.buffer.finish() : reader.buffer.append(chunk)
        for line in lines {
            switch HelperLine(line) {
            case .event(.unknown): continue
            case .event(let event): continuation.yield(.helper(event))
            case .malformed(let text, _): continuation.yield(.malformedLine(text))
            }
        }
    }

    private func exited(_ ended: Process) {
        guard ended === process else { return }
        process = nil
        try? stdin?.close()
        stdin = nil
        guard wanted else {
            continuation.yield(.stopped)
            return
        }
        let uptime = Date().timeIntervalSince(launchedAt)
        continuation.yield(.crashed(status: ended.terminationStatus, uptime: uptime))
        let delay = backoff.delay(afterRunOf: uptime)
        continuation.yield(.restartScheduled(delay: delay))
        let work = DispatchWorkItem { [weak self] in
            self?.restartWork = nil
            self?.launch(restart: true)
        }
        restartWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func wait(for process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline { return false }
            usleep(10_000)
        }
        return true
    }
}

/// One run's partial stdout line. Used only on the supervisor's queue.
private final class StdoutReader: @unchecked Sendable {
    var buffer = LineBuffer()
}
