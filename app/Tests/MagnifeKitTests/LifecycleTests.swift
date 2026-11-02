import Foundation
import GRDB
import GRDBSQLite
import MagnifeKit
import Testing

/// S-008: the stored traces after a quit, read before the helper is up.
@Suite("Relaunch", .serialized)
struct LifecycleTests {
    @Test("a writer that keeps its -wal (persistent WAL) leaves a database the reader opens alone, same rows, same order")
    func persistentWALReopens() async throws {
        let dir = try TempDir("relaunch")
        defer { dir.remove() }
        let url = dir.file("magnife.sqlite")
        let writer = try makeWriter(at: url)
        try await writer.write { db in
            // What the helper sets on its connection (ingest/internal/store).
            var persist: Int32 = 1
            #expect(sqlite3_file_control(db.sqliteConnection, "main", SQLITE_FCNTL_PERSIST_WAL, &persist) == SQLITE_OK)
            for n in 1...4 { try insertTrace(db, id: traceID(n), startNs: Int64(n) * 1_000, seq: Int64(n)) }
        }
        let running = try await TelemetryReader.open(at: url)
        let before = try await running.tracePage().traces.map(\.traceID)
        try writer.close()
        #expect(exists(url, suffix: "-wal"))

        let relaunched = try await TelemetryReader.open(at: url)
        let after = try await relaunched.tracePage()
        #expect(after.traces.map(\.traceID) == before)
        #expect(before == (1...4).reversed().map(traceID))
        #expect(after.lastSeq == 4)
    }

    @Test("with no -wal the reader waits on a file that may hold traces; a missing file holds none")
    func notReadyMayHoldTraces() async throws {
        let dir = try TempDir("relaunch-nowal")
        defer { dir.remove() }
        let url = dir.file("magnife.sqlite")
        await #expect(throws: StoreError.missing) { _ = try await TelemetryReader.open(at: url) }
        #expect(!StoreError.missing.mayHoldTraces)

        do {
            let writer = try makeWriter(at: url)
            try await writer.write { try insertTrace($0, id: traceID(1), startNs: 1) }
            try writer.close()
        }
        // A stock SQLite writer (the helper before S-008) deletes both after a clean close.
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
        await #expect(throws: StoreError.notReady) { _ = try await TelemetryReader.open(at: url) }
        #expect(StoreError.notReady.mayHoldTraces)
        #expect(!StoreError.cannotOpen("x").mayHoldTraces)
        #expect(!StoreError.unsupportedVersion(found: 2, expected: 1).mayHoldTraces)
    }
}
