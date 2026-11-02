import Foundation

/// Why the database cannot be read yet, or at all.
public enum StoreError: Error, Sendable, Equatable {
    /// The file does not exist: the helper has not created it yet.
    case missing
    /// The file exists but the helper has not opened it: a read-only
    /// connection cannot open a WAL database without its -wal file.
    case notReady
    /// The schema version is not the one this app reads.
    case unsupportedVersion(found: Int, expected: Int)
    case cannotOpen(String)

    /// True when waiting for the helper can fix it.
    public var isTransient: Bool {
        switch self {
        case .missing, .notReady: true
        case .unsupportedVersion, .cannotOpen: false
        }
    }

    /// True when the file may already hold traces the reader cannot see yet:
    /// it exists, but the helper has not opened it. The list then stays blank
    /// rather than saying "No Traces Yet" (S-008); a missing file holds none.
    public var mayHoldTraces: Bool { self == .notReady }

    /// The sentence the window shows.
    public var message: String {
        switch self {
        case .missing, .notReady:
            "Waiting for the receiver to open the database."
        case .unsupportedVersion(let found, let expected):
            "This database has schema version \(found), and this version of Magnife reads version \(expected). Update Magnife."
        case .cannotOpen(let reason):
            "The database cannot be opened: \(reason)"
        }
    }
}
