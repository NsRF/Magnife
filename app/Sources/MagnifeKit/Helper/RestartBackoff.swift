import Foundation

/// The wait before restarting a crashed helper: 0.5 s, doubling to 30 s,
/// back to 0.5 s after a run that stayed up 60 s (research/platform.md).
public struct RestartBackoff: Sendable, Equatable {
    public var initial: TimeInterval
    public var maximum: TimeInterval
    /// A run at least this long counts as stable and resets the wait.
    public var stableAfter: TimeInterval
    public private(set) var next: TimeInterval

    public init(initial: TimeInterval = 0.5, maximum: TimeInterval = 30, stableAfter: TimeInterval = 60) {
        self.initial = initial
        self.maximum = maximum
        self.stableAfter = stableAfter
        next = initial
    }

    /// The wait after a run of `uptime` seconds ended.
    public mutating func delay(afterRunOf uptime: TimeInterval) -> TimeInterval {
        if uptime >= stableAfter { next = initial }
        let delay = next
        next = min(next * 2, maximum)
        return delay
    }
}
