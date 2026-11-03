import Foundation
import MagnifeKit

/// The window's subtitle and the sidebar's services (with their error
/// counts) as shown: under a flood they change at most once a second
/// (docs/ux.md, S-030 States), so the title bar and the sidebar are not
/// laid out again for every batch. A change people made (a scope, a
/// filter, Pause) shows at once; only what batch refreshes change waits.
/// `subtitle` and `services` stay the model's current values.
extension AppModel {
    /// Starts following `subtitle` and `services` (AppModel.start, snapshot and self-test runs too).
    func followCounts() {
        let (subtitle, services) = withObservationTracking {
            (self.subtitle, self.services)
        } onChange: { [weak self] in
            // Called before the change lands: read the new values on the next turn.
            let paced = RefreshPacing.isBatch
            Task { @MainActor [weak self] in self?.countsChanged(paced: paced) }
        }
        if shownSubtitle != subtitle { shownSubtitle = subtitle }
        if shownServices != services { shownServices = services }
    }

    private func countsChanged(paced: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let delay = paced ? countThrottle.delay(at: now) : 0
        guard delay > 0 else {
            countTask?.cancel()
            countTask = nil
            countThrottle.fired(at: now)
            followCounts()
            return
        }
        // Keep following meanwhile; the latest values show when the second is up.
        guard countTask == nil else { return }
        countTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.countTask = nil
            self.countThrottle.fired(at: ProcessInfo.processInfo.systemUptime)
            self.followCounts()
        }
    }
}

/// Whether what changes now comes from the helper's batches (decision 160:
/// pacing applies to what batches change, not to what people do). A task
/// local, set for the length of one refresh and inherited by the tasks it
/// starts: a refresh people asked for that overlaps a batch refresh is
/// never paced, and a batch refresh never loses its pacing half-way
/// (M3 review 6, where one stored flag was shared by both).
nonisolated enum RefreshPacing {
    @TaskLocal static var isBatch = false
}
