import AppKit
import MagnifeKit

/// 10-compare (S-036): the compare set's fast and slow GET /account/orders
/// with the slow query's strip line clicked; -all with Show Only Differences
/// off; -picker, Compare With… (Search in compare mode) over the main
/// window; -different, two of the seed set's traces with little in common.
extension Snapshot {
    static func captureCompare(_ model: AppModel, dir: String, mode: String) async {
        let main = model.storeURL
        let compare = model.compare
        await model.useStore(at: SnapshotPage.compareStore(next: main))
        await model.reload()
        for _ in 0..<60 where model.traces.count < 2 { try? await Task.sleep(for: .milliseconds(50)) }
        let fast = SelfTest.compareFast, slow = SelfTest.compareSlow
        model.selectedTraceID = fast
        if !compare.showsOnlyDifferences { model.toggleOnlyDifferences() }
        model.compare(a: fast, b: slow)
        await waitForComparison(compare)
        if let comparison = compare.comparison, let query = comparison.differences.first(where: { $0.kind == .slower }) {
            model.selectDifference(query)
        }
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(SnapshotPage.compare.rawValue)-\(mode).png", window: CompareWindow.window)

        model.toggleOnlyDifferences()
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(SnapshotPage.compare.rawValue)-all-\(mode).png", window: CompareWindow.window)
        model.toggleOnlyDifferences()

        // Compare With… (⇧⌘K): Search over the main window, Same Route first.
        CompareWindow.close()
        model.showCompareSearch(for: fast)
        for _ in 0..<60 where model.searchSameRoute.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(SnapshotPage.compare.rawValue)-picker-\(mode).png", window: MainWindow.window)
        model.closeSearch()

        // Little in common: the seed set's healthy checkout and its N+1, two routes.
        await model.useStore(at: main)
        await model.reload()
        let healthy = model.traces.first { $0.route == "GET /checkout" } ?? model.traces.first
        let other = model.traces.first { $0.route == "GET /account/orders" } ?? model.traces.last
        if let healthy, let other, healthy.id != other.id {
            model.compare(a: healthy.traceID, b: other.traceID)
            await waitForComparison(compare)
            try? await Task.sleep(for: .seconds(0.8))
            capture(to: "\(dir)/\(SnapshotPage.compare.rawValue)-different-\(mode).png", window: CompareWindow.window)
        } else {
            print("SNAPSHOT no two seed traces to compare")
        }
        CompareWindow.close()
        compare.pair = nil
        compare.comparison = nil
        MenuState.shared.update(hasComparison: false)
        model.selectedTraceID = nil
    }

    private static func waitForComparison(_ compare: CompareModel) async {
        for _ in 0..<80 where compare.comparison == nil || compare.isLoading || CompareWindow.window == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
