import Foundation
import MagnifeKit

/// S-010: Pause and Resume in the real window, with traces sent to the seed
/// helper that keeps writing the store while the list is paused.
extension SelfTest {
    static func checkPause(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let sender = env["APP_SAMPLE_SENDER"].map(URL.init(fileURLWithPath:)),
              let grpc = env["APP_SEED_GRPC"], let http = env["APP_SEED_HTTP"], let reader = model.reader else {
            return check("APP_SEED_GRPC and APP_SEED_HTTP name the seed helper (tools/selftest.sh)", false)
        }
        /// Sends `spans` spans of 2-span traces and waits until they are stored; returns the new traces.
        func send(spans: Int) async -> Int {
            let before = (try? await reader.traceCount()) ?? 0
            let result = await run(sender, ["--protocol", "http-protobuf", "--scenarios", "exception",
                                            "--volume", String(spans), "--grpc", grpc, "--http", http])
            let traces = result.output.firstMatch(of: /(\d+) spans in (\d+) traces/).flatMap { Int($0.2) } ?? 0
            for _ in 0..<50 where (try? await reader.traceCount()) ?? 0 < before + traces {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return ((try? await reader.traceCount()) ?? 0) - before
        }

        model.sidebar = .allTraces
        model.showNewestTraces()
        await model.reload()
        guard model.traces.count > 1 else { return check("the list has traces to pause", false) }
        // The second row, so the traces that arrive push it below the first page.
        let selected = model.traces[1].id
        model.selectedTraceID = selected
        _ = await waitUntil(3) { !model.waterfall.isEmpty }
        let spanCount = model.waterfall.count

        model.togglePause()
        check("Pause holds the list at the seq its rows were read at",
              model.isPaused && model.pausedSeq == model.listBaseSeq && MenuState.shared.isPaused
                && model.subtitle.hasPrefix("Paused · "), model.subtitle)
        let rows = model.traces
        let openTrace = model.openTrace
        // The Logs list is not showing: it pauses at the newest log stored, not at rows from an earlier visit.
        let lastLog = (try? await reader.lastLogID()) ?? -1
        check("pausing in the Traces view pauses the Logs list at the newest log",
              await waitUntil(2) { model.logPausedID == lastLog } && model.logs.isEmpty,
              "paused at \(model.logPausedID ?? -1), newest \(lastLog), \(model.logs.count) rows")

        // A span from a new service joins the selected trace, and new traces arrive.
        let now = UInt64(Date().timeIntervalSince1970 * 1e9)
        let posted = await post(port: Int(http.split(separator: ":").last ?? "") ?? 0, path: "/v1/traces", body: """
            {"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"pause-check"}}]},
            "scopeSpans":[{"spans":[{"traceId":"\(selected)","spanId":"5e1f7e5700000f01","name":"late span","kind":1,
            "startTimeUnixNano":"\(now)","endTimeUnixNano":"\(now + 1_000_000)"}]}]}]}
            """)
        let arrived = await send(spans: 440)
        for _ in 0..<30 where (try? await reader.trace(id: selected))?.spanCount ?? 0 <= openTrace?.spanCount ?? 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        await model.reload()
        try? await Task.sleep(for: .milliseconds(300))
        let stored = try? await reader.trace(id: selected)
        check("while paused, the list does not change, not even the row that grew",
              model.traces == rows && model.selectedTraceID == selected)
        check("while paused, the open waterfall holds still",
              model.waterfall.count == spanCount && model.openTrace == openTrace, "\(model.waterfall.count) spans")
        check("ingestion keeps going while paused",
              posted == 200 && arrived > TraceList.pageSize && stored?.spanCount == (openTrace?.spanCount ?? 0) + 1,
              "posted \(posted), \(arrived) traces, \(stored?.spanCount ?? -1) spans")
        check("the bar counts the traces that arrived meanwhile",
              model.newTraceCount == arrived && !model.showsNewTracesButton
                && TraceList.pausedText(newCount: model.newTraceCount)
                    == "Paused. \(arrived.formatted()) new traces. Magnife is still receiving.",
              "\(arrived) sent, \(model.newTraceCount) counted")
        check("the sidebar keeps updating while paused", model.services.contains { $0.name == "pause-check" })

        // Another scope while paused: read up to the pause point, the count follows the scope.
        // The scope of the traces that arrived, which the seed traces have too.
        let pausedAt = model.pausedSeq ?? 0
        let scope = (try? await reader.latestTraces(limit: 1).first?.rootService) ?? "orders"
        model.sidebar = .service(scope)
        await model.reload()
        let newInScope = (try? await reader.heldTraces(base: pausedAt, applied: 0, shown: [], service: scope).newCount) ?? -1
        check("a scope changed while paused reads up to the pause point, and its count follows it",
              model.isPaused && !model.traces.isEmpty && model.traces.allSatisfy { $0.firstSeq <= pausedAt }
                && model.newTraceCount == newInScope && newInScope > 0,
              "\(scope): \(model.traces.count) rows, \(model.newTraceCount) counted, \(newInScope) expected")
        model.sidebar = .allTraces
        await model.reload()
        check("back to All Services, still paused, the same rows",
              model.isPaused && model.traces.map(\.id) == rows.map(\.id) && model.newTraceCount == arrived)
        if model.selectedTraceID == nil { model.selectedTraceID = selected }

        let resumeLimit = TraceList.resumeLimit(selectedRow: model.traces.firstIndex { $0.id == selected },
                                                newCount: model.newTraceCount)
        model.togglePause()
        // A refresh while Resume reads (traffic keeps coming) reads as many rows.
        await model.reload()
        let newest = try? await reader.latestTraces(limit: 1).first
        let resumed = await waitUntil(3) {
            !model.isPaused && model.traces.first?.id == newest?.id && model.traces.contains { $0.id == selected }
        }
        let row = model.traces.firstIndex { $0.id == selected } ?? -1
        check("Resume inserts them at the top and keeps the selected trace selected",
              resumed && model.selectedTraceID == selected && model.traces.count >= rows.count + arrived
                && row >= 0 && !MenuState.shared.isPaused && !model.subtitle.hasPrefix("Paused"),
              "\(model.traces.count) rows, selected at row \(row)")
        check("Resume reads down to the selected trace, not every row stored",
              model.traces.count <= resumeLimit && model.traces.count > row, "\(model.traces.count) rows, limit \(resumeLimit)")
        let inView = await waitUntil(2) { model.listScroller.isRowVisible(row) }
        check("the selected trace is in view after Resume", inView,
              "offset \(model.listScroller.offset), first row \(model.listScroller.firstVisibleRow ?? -1), row \(row)")
        check("after Resume the list holds still only when scrolled away, with nothing waiting",
              model.isListHeld == model.listScroller.isAwayFromTop && model.newTraceCount == 0)
        check("the waterfall catches up after Resume", await waitUntil(3) { model.waterfall.count == spanCount + 1 },
              "\(model.waterfall.count) spans")

        // Resume's task ends after its reveal, which waits for the table's rows (paced, S-030).
        let settled = await waitUntil(2) { model.resumeRows == nil }
        check("a refresh during Resume kept the selected trace in the list",
              model.traces.contains { $0.id == selected } && settled)

        // Nothing selected: Resume reads one page, however many arrived.
        model.selectedTraceID = nil
        model.showNewestTraces()
        await model.reload()
        model.togglePause()
        _ = await send(spans: 440)
        await model.reload()
        model.togglePause()
        _ = await waitUntil(3) { !model.isPaused && model.resumeRows == nil && model.newTraceCount == 0 }
        check("with nothing selected, Resume reads one page", model.traces.count == TraceList.pageSize,
              "\(model.traces.count) rows")
        await model.reload()
    }
}
