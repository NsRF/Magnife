import Foundation
import MagnifeKit

/// The receiver: starting the helper, its events, Try Again (S-001, S-002, S-008).
extension AppModel {
    /// Starts the helper (unless APP_HELPER=none) on the configured ports.
    /// The self-test passes another executable and free ports.
    func startReceiver(executable: URL? = AppModel.helperExecutable(),
                       ports: (grpc: Int, http: Int) = HelperConfiguration.ports()) {
        guard let executable, supervisor == nil else { return }
        if !StoreLocation.isOverridden() {
            // The helper creates the file; the folder may not exist on first launch.
            try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        }
        let configuration = HelperConfiguration(executableURL: executable, databaseURL: storeURL,
                                                grpcPort: ports.grpc, httpPort: ports.http,
                                                retentionSeconds: retentionSeconds)
        let supervisor = HelperSupervisor(configuration: configuration)
        self.supervisor = supervisor
        startQuietClock()
        Task { [weak self] in
            for await event in supervisor.events { self?.handle(event) }
        }
        supervisor.start()
    }

    /// Blocks until the helper exited (applicationWillTerminate).
    func stopHelper() {
        supervisor?.stopAndWait()
    }

    /// stopHelper without blocking the main actor (self-test).
    func stopHelperAndWait() async {
        await supervisor?.stop()
    }

    /// The helper's pid while it runs.
    var helperPID: Int32? { supervisor?.pid }

    /// nil when APP_HELPER=none; a path in APP_HELPER; else the bundled helper.
    static func helperExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        switch environment["APP_HELPER"] {
        case "none": nil
        case let path? where !path.isEmpty: URL(fileURLWithPath: path)
        default: HelperConfiguration.bundledExecutable()
        }
    }

    /// Try Again: asks the helper to bind busy ports again and report them.
    func retryPorts() {
        helperProblem = nil
        try? supervisor?.send(.retry)
    }

    /// The toolbar's status words, or nil during a quick start.
    var receiverStatusText: String? {
        receiver.statusText(startingFor: quietStartOver ? ReceiverStatus.quietStart : 0)
    }

    var receiverTooltip: String {
        let ports = supervisor.map { ($0.configuration.grpcPort, $0.configuration.httpPort) } ?? HelperConfiguration.ports()
        return receiver.tooltip(grpcPort: ports.0, httpPort: ports.1)
    }

    // MARK: Helper events

    func handle(_ event: SupervisorEvent) {
        onHelperEvent?(event)
        switch event {
        case .started(_, let restart):
            if restart { receiverRestarted = true }
        case .helper(.ports(let ports)):
            receiver = .ports(ports)
            // The helper sends "ports" after the schema is ready.
            if reader == nil { Task { await openStore() } }
        case .helper(.batch(let batch)):
            if reader == nil {
                Task { await openStore() }
            } else {
                requestRefresh()
            }
            if receiverRestarted && !batch.traces.isEmpty { receiverRestarted = false }
            // Paused too: the icon counts and notifications keep coming (docs/ux.md, S-010 States).
            noteFailedTraces(batch.errorTraces)
            notifyFailures(batch.errorTraces)
        case .helper(.pruned):
            // Pruned rows leave the lists and the sidebar counts drop (S-015);
            // a selected trace that was deleted shows "Trace No Longer Stored".
            // The Logs counts are counted again in full: logs were deleted.
            logCountMark = nil
            requestRefresh()
            refreshDatabaseSize()
        case .helper(.error(let message)):
            helperProblem = ReceiverStatus.problem(message)
        case .helper(.unknown):
            break
        case .malformedLine(let line):
            FileHandle.standardError.write(Data("magnife: ignored helper line: \(line)\n".utf8))
        case .crashed:
            receiver = .starting
            startQuietClock()
        case .restartScheduled, .stopped:
            break
        case .launchFailed(let message):
            receiver = .stopped(message)
            helperMessage = "The receiver could not start. \(message)"
        }
    }

    /// "Starting receiver…" appears only when starting takes over half a second.
    private func startQuietClock() {
        quietStartOver = false
        quietStartTask?.cancel()
        quietStartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ReceiverStatus.quietStart))
            guard !Task.isCancelled else { return }
            self?.quietStartOver = true
        }
    }

    /// Snapshot pages show the receiver as it looks when both ports listen.
    func showReceiverListening() {
        let ports = HelperConfiguration.ports()
        receiver = .ports(ReceiverPorts(grpc: PortStatus(addr: "127.0.0.1:\(ports.grpc)", state: .listening),
                                        http: PortStatus(addr: "127.0.0.1:\(ports.http)", state: .listening)))
    }
}
