import Foundation
import MagnifeKit

/// Failure notifications (S-028): each batch line's `error_traces` (the
/// traces whose status became Error in it) are read off the main actor and
/// handed to `failureNotifier`, paused or not.
extension AppModel {
    /// A batch line's traces with errors. Ids wait while the store is not
    /// open yet; `reload` picks them up.
    func notifyFailures(_ ids: [String]) {
        guard failureNotifier.isEnabled, !ids.isEmpty else { return }
        failureNotifier.pendingIDs += ids
        drainFailures()
    }

    /// One read at a time; ids that arrive during it go in the next.
    func drainFailures() {
        let notifier = failureNotifier
        guard notifier.drainTask == nil, !notifier.pendingIDs.isEmpty, reader != nil else { return }
        notifier.drainTask = Task { [weak self] in
            while let self, let reader = self.reader, !notifier.pendingIDs.isEmpty {
                let ids = notifier.pendingIDs
                notifier.pendingIDs = []
                guard await notifier.mayPost() else { continue }
                guard let traces = try? await reader.failedTraces(ids: ids) else { continue }
                notifier.post(traces)
            }
            notifier.drainTask = nil
        }
    }
}
