import Foundation
import GRDB
import Testing

/// Verifies how a read-only GRDB DatabasePool behaves on the helper's WAL
/// database. The app's store design rests on these results.
@Suite("Read-only pool on a WAL database", .serialized)
struct WALReadonlyTests {
    @Test("sees commits from a writer that stays open")
    func seesNewCommits() async throws {
        let dir = try TempDir("wal-live")
        defer { dir.remove() }
        let url = dir.file("magnife.sqlite")
        let writer = try makeWriter(at: url)
        try await writer.write { try insertTrace($0, id: traceID(1), startNs: 1, seq: 1) }

        let pool = try readonlyPool(at: url)
        #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM traces") } == 1)

        try await writer.write { try insertTrace($0, id: traceID(2), startNs: 2, seq: 2) }
        #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM traces") } == 2)
        #expect(try await pool.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'last_seq'") } == "2")
        #expect(try await pool.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") } == "wal")
    }

    @Test("refuses to write")
    func refusesWrites() async throws {
        let dir = try TempDir("wal-write")
        defer { dir.remove() }
        let url = dir.file("magnife.sqlite")
        let writer = try makeWriter(at: url)
        let pool = try readonlyPool(at: url)
        await #expect(throws: DatabaseError.self) {
            try await pool.write { try $0.execute(sql: "DELETE FROM traces") }
        }
        await #expect(throws: DatabaseError.self) {
            try await pool.read { try $0.execute(sql: "INSERT INTO meta (key, value) VALUES ('x', 'y')") }
        }
        _ = writer
    }

    @Test("cannot open when the -wal file is missing, even in a writable folder")
    func missingWALFails() async throws {
        let dir = try TempDir("wal-closed")
        defer { dir.remove() }
        let url = dir.file("magnife.sqlite")
        do {
            let writer = try makeWriter(at: url)
            try await writer.write { try insertTrace($0, id: traceID(1), startNs: 1) }
            try writer.close()
        }
        removeSidecars(url)
        #expect {
            _ = try readonlyPool(at: url)
        } throws: { error in
            print("WAL-VERIFY no -wal, no -shm, writable folder: \(error)")
            return (error as? DatabaseError)?.resultCode == .SQLITE_CANTOPEN
        }
        // An -shm alone is not enough either.
        FileManager.default.createFile(atPath: url.path + "-shm", contents: nil)
        #expect(throws: DatabaseError.self) { _ = try readonlyPool(at: url) }
        // The reader never created the -wal.
        #expect(!exists(url, suffix: "-wal"))

        // Once the helper opens the file (creating the -wal), the reader opens
        // and keeps seeing commits, also after the helper closes again.
        let writer = try makeWriter(at: url)
        let pool = try readonlyPool(at: url)
        #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM traces") } == 1)
        try await writer.write { try insertTrace($0, id: traceID(2), startNs: 2, seq: 2) }
        #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM traces") } == 2)
        try writer.close()
        #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM traces") } == 2)
    }

    @Test("opens when only an -wal file exists, and creates the -shm itself")
    func walWithoutShmOpens() async throws {
        let dir = try TempDir("wal-only")
        defer { dir.remove() }
        let url = dir.file("magnife.sqlite")
        do {
            let writer = try makeWriter(at: url)
            try await writer.write { try insertTrace($0, id: traceID(1), startNs: 1) }
            try writer.close()
        }
        removeSidecars(url)
        FileManager.default.createFile(atPath: url.path + "-wal", contents: nil)
        let pool = try readonlyPool(at: url)
        #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM traces") } == 1)
        print("WAL-VERIFY empty -wal, no -shm: opened; shm created=\(exists(url, suffix: "-shm"))")
        #expect(exists(url, suffix: "-shm"))
    }

    @Test("with no -wal or -shm in a read-only folder, opening fails")
    func readonlyFolderWithoutShm() async throws {
        let dir = try TempDir("wal-rofolder")
        defer {
            chmod(dir.url.path, 0o755)
            dir.remove()
        }
        let url = dir.file("magnife.sqlite")
        do {
            let writer = try makeWriter(at: url)
            try writer.close()
        }
        removeSidecars(url)
        chmod(dir.url.path, 0o555)
        var outcome = "opened and read"
        do {
            let pool = try readonlyPool(at: url)
            _ = try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM traces") }
        } catch let error as DatabaseError {
            outcome = "failed: \(error.resultCode) \(error.message ?? "")"
        }
        print("WAL-VERIFY read-only folder, no -shm: \(outcome)")
        #expect(outcome.hasPrefix("failed"))
    }

    @Test("a missing file fails with SQLITE_CANTOPEN")
    func missingFile() throws {
        let dir = try TempDir("wal-missing")
        defer { dir.remove() }
        let url = dir.file("magnife.sqlite")
        #expect {
            _ = try readonlyPool(at: url)
        } throws: { error in
            print("WAL-VERIFY missing file: \(error)")
            return (error as? DatabaseError)?.resultCode == .SQLITE_CANTOPEN
        }
        // And opening read-only never creates the file.
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a file that is not in WAL mode yet")
    func notWALYet() async throws {
        let dir = try TempDir("wal-delete")
        defer { dir.remove() }
        let url = dir.file("magnife.sqlite")
        let writer = try DatabaseQueue(path: url.path)
        try await writer.write { try $0.execute(sql: "CREATE TABLE t (x)") }
        let pool = try readonlyPool(at: url)
        let mode = try await pool.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        print("WAL-VERIFY rollback-journal file read-only: journal_mode=\(mode ?? "nil")")
        #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM t") } == 0)
    }

    @Test("a writer in another process: live commits, then kill -9")
    func otherProcessWriter() async throws {
        let dir = try TempDir("wal-process")
        defer { dir.remove() }
        let url = dir.file("magnife.sqlite")
        do {
            let writer = try makeWriter(at: url)
            try writer.close()
        }
        // sqlite3 holds a write connection open, like the helper.
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [url.path]
        let input = Pipe()
        sqlite.standardInput = input
        sqlite.standardOutput = FileHandle.nullDevice
        try sqlite.run()
        func send(_ sql: String) throws { try input.fileHandleForWriting.write(contentsOf: Data((sql + "\n").utf8)) }
        try send("PRAGMA journal_mode=WAL;")
        try send("INSERT INTO meta (key, value) VALUES ('last_seq', '7') ON CONFLICT(key) DO UPDATE SET value = excluded.value;")

        let pool = try readonlyPool(at: url)
        try await waitUntil { try await pool.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'last_seq'") } == "7" }
        try send("UPDATE meta SET value = '8' WHERE key = 'last_seq';")
        try await waitUntil { try await pool.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'last_seq'") } == "8" }

        // A crash leaves the -wal and -shm behind; the reader keeps working.
        try send("UPDATE meta SET value = '9' WHERE key = 'last_seq';")
        try await Task.sleep(for: .milliseconds(300))
        kill(sqlite.processIdentifier, SIGKILL)
        sqlite.waitUntilExit()
        print("WAL-VERIFY after kill -9: wal=\(exists(url, suffix: "-wal")) shm=\(exists(url, suffix: "-shm"))")
        #expect(try await pool.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'last_seq'") } == "9")
        try pool.close()
        // A fresh read-only pool after the crash sees the committed data too.
        let fresh = try readonlyPool(at: url)
        #expect(try await fresh.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'last_seq'") } == "9")
    }

    /// Apple's SQLite keeps an empty -wal and the -shm after the last
    /// connection closes; stock SQLite builds (like the Go helper's) delete
    /// both. Deleting them after a clean close gives the stock state.
    private func removeSidecars(_ url: URL) {
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
        #expect(!exists(url, suffix: "-wal") && !exists(url, suffix: "-shm"))
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<50 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("condition not met within 2.5 s")
    }
}
