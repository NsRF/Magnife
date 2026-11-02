import Foundation

/// A stable color slot per service name, so a service has one color in the
/// sidebar, list, and waterfall (design decision 4). The palette itself is in
/// the app (UI/ServicePalette.swift).
public enum ServiceColor {
    public static let slotCount = 12

    /// FNV-1a of the name's UTF-8 bytes, so the slot never changes between runs
    /// (Swift's hashValue is seeded per process).
    public static func slot(for service: String, slots: Int = slotCount) -> Int {
        var hash: UInt32 = 0x811C_9DC5
        for byte in service.utf8 {
            hash ^= UInt32(byte)
            hash &*= 0x0100_0193
        }
        return Int(hash % UInt32(slots))
    }
}
