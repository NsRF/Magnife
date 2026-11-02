import Foundation

/// "Database size" in Settings > General (S-016): the size on disk of the
/// database file plus its WAL, read from the file system, so it shows at
/// once, even before the database opens. SQLite reuses the pages pruning
/// frees, so the file stops growing at the retention's size rather than
/// shrinking after a Delete (PROGRESS decision 102).
public enum DatabaseSize {
    /// The database and its -wal file, in bytes; 0 for files that do not exist yet.
    public static func bytes(of database: URL) -> Int64 {
        [database, URL(fileURLWithPath: database.path + "-wal")].reduce(0) { total, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            return total + (size ?? 0)
        }
    }

    /// "182 MB", "4 KB", "0 bytes": Finder's units (powers of 1,000).
    public static func text(_ bytes: Int64) -> String {
        formatter(includesCount: true, includesUnit: true).string(fromByteCount: bytes)
    }

    /// What VoiceOver reads: "182 megabytes".
    public static func spoken(_ bytes: Int64) -> String {
        let count = formatter(includesCount: true, includesUnit: false).string(fromByteCount: bytes)
        let unit = formatter(includesCount: false, includesUnit: true).string(fromByteCount: bytes)
        let words = ["bytes": "bytes", "byte": "byte", "KB": "kilobytes", "MB": "megabytes", "GB": "gigabytes",
                     "TB": "terabytes"]
        return "\(count) \(words[unit] ?? unit)"
    }

    private static func formatter(includesCount: Bool, includesUnit: Bool) -> ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        formatter.includesCount = includesCount
        formatter.includesUnit = includesUnit
        return formatter
    }
}
