import Foundation
import MagnifeKit

/// Sharing traces as files (v0.2), end to end: the seed set's HTTP 500 trace
/// is exported from the window's store, then imported through the real
/// bundled helper into a fresh database the window reads; the trace opens
/// with the same spans, findings and logs. A file that is not OTLP JSON
/// comes back as "import_failed" and stores nothing.
extension SelfTest {
    private static var sharingRoot: URL { TestRun.directory.appending(path: "sharing") }

    static func checkSharing(_ model: AppModel) async {
        try? FileManager.default.removeItem(at: sharingRoot)
        try? FileManager.default.createDirectory(at: sharingRoot, withIntermediateDirectories: true)
        guard let helperURL = AppModel.helperExecutable(environment: [:]),
              FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return check("the bundled helper exists (tools/selftest.sh)", false)
        }

        // Export: the seed set's HTTP 500 trace, as the window shows it. In a
        // full run the live list checks before this one sent the seed helper
        // hundreds more traces, which push it off the list's first page (200
        // rows, newest first): the list is filtered to checkout-api's errors.
        model.showContentMode(.traces)
        model.applyTraceFilter(TraceFilter(service: "checkout-api", statuses: [.error]))
        _ = await waitUntil(3) { model.traces.contains { $0.route == "POST /checkout/pay" } }
        guard let original = model.traces.first(where: { $0.route == "POST /checkout/pay" }), let reader = model.reader else {
            let stored = (try? await model.reader?.latestTraces(limit: 100_000))?
                .filter { $0.route == "POST /checkout/pay" }.count
            let total = (try? await model.reader?.traceCount()) ?? -1
            return check("the seed set's HTTP 500 trace is listed", false,
                         "\(model.traces.count) rows listed, \(total) traces stored, \(stored.map(String.init) ?? "?") POST /checkout/pay; "
                         + "filter \(TraceQuery.format(model.traceFilter)), held \(model.isListHeld), paused \(model.isPaused), "
                         + "store \(model.storeState)")
        }
        model.selectedTraceID = original.traceID
        _ = await waitUntil(3) { model.waterfall.count == original.spanCount }
        let originalFindings = model.openTraceFindings.findings.map { "\($0.kind) \($0.spanIDs)" }
        let originalLogs = (try? await reader.logs(traceID: original.traceID))?.map(\.body) ?? []
        let export = try? await reader.exportTrace(traceID: original.traceID)
        check("Export Trace reads every span and log of the trace",
              export?.spanCount == original.spanCount && export?.logCount == originalLogs.count,
              "\(export?.spanCount ?? 0) spans, \(export?.logCount ?? 0) logs")
        let file = sharingRoot.appending(path: TraceExport.suggestedFileName(for: original))
        do { try export?.data.write(to: file) } catch { check("the export is written", false, "\(error)") }

        // Import: a fresh store and the real helper; the window reads that store, unfiltered.
        model.applyTraceFilter(.cleared)
        let store = sharingRoot.appending(path: "magnife.sqlite")
        let helper = AppModel(storeURL: store)
        helper.startReceiver(executable: helperURL, ports: (grpc: freePort(), http: freePort()))
        _ = await waitUntil(5) { helper.receiver.isReceiving && helper.storeState == .ready }
        await model.useStore(at: store)
        model.sidebar = .allTraces
        model.selectedTraceID = nil
        var failures: [(path: String, message: String)] = []
        helper.onHelperEvent = { [weak model] event in
            switch event {
            case .helper(.importFailed(let path, let message)): failures.append((path, message))
            case .helper(.batch), .helper(.imported): model?.handle(event)
            default: break
            }
        }
        let keptSupervisor = model.supervisor
        model.supervisor = helper.supervisor

        let started = Date()
        model.importTraces(from: [file])
        let opened = await waitUntil(5) {
            model.selectedTraceID == original.traceID && model.waterfall.count == original.spanCount
        }
        check("Import Traces opens the imported trace with all its spans", opened,
              "selected \(model.selectedTraceID ?? "none"), \(model.waterfall.count) spans, "
              + "in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        let listed = await waitUntil(3) { model.traces.contains { $0.traceID == original.traceID } }
        let row = model.traces.first { $0.traceID == original.traceID }
        check("the imported trace is listed as it was exported",
              listed && row?.route == original.route && row?.status == original.status && row?.durationNs == original.durationNs,
              "\(row.map { "\($0.route) \($0.status) \($0.durationNs)" } ?? "not listed")")
        _ = await waitUntil(2) { model.openTraceFindings.findings.count == originalFindings.count }
        let findings = model.openTraceFindings.findings.map { "\($0.kind) \($0.spanIDs)" }
        check("the imported trace has the same findings", findings == originalFindings && !findings.isEmpty, "\(findings)")
        let logs = (try? await model.reader?.logs(traceID: original.traceID))?.map(\.body) ?? []
        check("the imported trace has the same logs", logs == originalLogs, "\(logs.count) of \(originalLogs.count)")

        // A file that is not OTLP JSON: an answer the app shows, and nothing stored.
        let notOTLP = sharingRoot.appending(path: "notes.txt")
        try? Data("these are notes\n".utf8).write(to: notOTLP)
        let countBefore = (try? await model.reader?.traceCount()) ?? -1
        try? helper.supervisor?.send(.importFile(path: notOTLP.path(percentEncoded: false)))
        let refused = await waitUntil(5) { !failures.isEmpty }
        check("a file that is not OTLP JSON is refused with a reason",
              refused && failures.first?.message.contains("not valid JSON") == true,
              failures.first?.message ?? "no answer")
        check("a refused file stores nothing", (try? await model.reader?.traceCount()) == countBefore)
        // Only the model that sent an import acts on its answer: the window's
        // was answered, and the helper's own model opened no alert for either.
        check("every import the window sent was answered", model.pendingImports.isEmpty, "\(model.pendingImports)")

        helper.onHelperEvent = nil
        model.supervisor = keptSupervisor
        let stopping = Date()
        await helper.stopHelperAndWait()
        let stopMs = Int(Date().timeIntervalSince(stopping) * 1000)
        check("the import helper stops at once", stopMs < 2000, "\(stopMs) ms")
        model.selectedTraceID = nil
        await model.useStore(at: model.storeURL)
        try? FileManager.default.removeItem(at: sharingRoot)
    }
}
