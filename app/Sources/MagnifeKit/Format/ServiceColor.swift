import Foundation

/// One color slot per service, the same in the sidebar, list, and waterfall
/// (design decision 4). Services take the palette's slots in the order they
/// were first seen (`services.first_seen_ns`, then name), so the first ten
/// services never share a color, and a service keeps its slot across launches:
/// the helper never deletes or rewrites a services row. The palette itself is
/// in the app (UI/ServicePalette.swift).
public struct ServiceColors: Sendable, Equatable {
    /// docs/ux.md, Colors: ten system colors.
    public static let paletteCount = 10

    private let slots: [String: Int]
    private let paletteCount: Int

    public init(services: [ServiceSummary] = [], paletteCount: Int = paletteCount) {
        self.paletteCount = paletteCount
        let ordered = services.sorted { ($0.firstSeenNs, $0.name) < ($1.firstSeenNs, $1.name) }
        var slots: [String: Int] = [:]
        for (rank, service) in ordered.enumerated() { slots[service.name] = rank % paletteCount }
        self.slots = slots
    }

    /// The service's slot. A name the services list does not have yet (its
    /// first span arrived after the last read) gets a stable hashed slot
    /// until the next read places it.
    public func slot(for service: String) -> Int {
        slots[service] ?? ServiceColor.slot(for: service, slots: paletteCount)
    }
}

public enum ServiceColor {
    /// FNV-1a of the name's UTF-8 bytes, so the slot never changes between runs
    /// (Swift's hashValue is seeded per process).
    public static func slot(for service: String, slots: Int = ServiceColors.paletteCount) -> Int {
        var hash: UInt32 = 0x811C_9DC5
        for byte in service.utf8 {
            hash ^= UInt32(byte)
            hash &*= 0x0100_0193
        }
        return Int(hash % UInt32(slots))
    }
}
