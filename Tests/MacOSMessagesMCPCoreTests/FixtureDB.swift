import Foundation
import SQLite3

enum FixtureError: Error {
    case sqlite(String)
}

final class FixtureDB {
    let path: String
    private var openHandle: OpaquePointer?

    init(walMode: Bool = false) throws {
        path = NSTemporaryDirectory() + "/macos-messages-fixture-\(UUID().uuidString).db"
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw FixtureError.sqlite("cannot create fixture db")
        }
        defer {
            if !walMode { sqlite3_close(db) }
        }

        if walMode {
            try FixtureDB.exec(db, "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;")
            openHandle = db
        }

        let schema = """
        CREATE TABLE chat (
            ROWID INTEGER PRIMARY KEY,
            chat_identifier TEXT,
            display_name TEXT,
            service_name TEXT
        );
        CREATE TABLE handle (
            ROWID INTEGER PRIMARY KEY,
            id TEXT,
            service TEXT
        );
        CREATE TABLE message (
            ROWID INTEGER PRIMARY KEY,
            text TEXT,
            attributedBody BLOB,
            is_from_me INTEGER DEFAULT 0,
            date INTEGER DEFAULT 0,
            handle_id INTEGER,
            service TEXT
        );
        CREATE TABLE chat_message_join (
            chat_id INTEGER,
            message_id INTEGER
        );
        """
        try FixtureDB.exec(db, schema)

        try FixtureDB.exec(db, """
        INSERT INTO chat (ROWID, chat_identifier, display_name, service_name) VALUES
            (1, 'alice@example.test', 'Alice', 'iMessage'),
            (2, 'chat12345', 'Family Group', 'iMessage');
        INSERT INTO handle (ROWID, id, service) VALUES
            (1, 'alice@example.test', 'iMessage'),
            (2, '+15551234567', 'SMS');
        """)

        try FixtureDB.insertMessage(db, rowid: 1, text: "Hello Bob", blob: nil, fromMe: 0, date: 700_000_000_000_000_000, handle: 1, service: "iMessage")
        try FixtureDB.insertMessage(db, rowid: 2, text: "Hi Alice", blob: nil, fromMe: 1, date: 700_000_100_000_000_000, handle: 0, service: "iMessage")
        let blob = FixtureDB.makeAttributedBodyBlob("Blob fallback text")
        try FixtureDB.insertMessage(db, rowid: 3, text: nil, blob: blob, fromMe: 0, date: 700_000_200_000_000_000, handle: 1, service: "iMessage")
        try FixtureDB.insertMessage(db, rowid: 4, text: "dinner at 7?", blob: nil, fromMe: 0, date: 700_000_300_000_000_000, handle: 2, service: "iMessage")

        try FixtureDB.exec(db, """
        INSERT INTO chat_message_join (chat_id, message_id) VALUES
            (1, 1), (1, 2), (1, 3),
            (2, 4);
        """)
    }

    deinit {
        if let openHandle { sqlite3_close(openHandle) }
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    static func makeAttributedBodyBlob(_ text: String) -> Data {
        var data = Data("bplist00 fake archive prefix NSString".utf8)
        let textBytes = Array(text.utf8)
        data.append(UInt8(textBytes.count))
        data.append(contentsOf: textBytes)
        return data
    }

    static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw FixtureError.sqlite(message)
        }
    }

    static func insertMessage(_ db: OpaquePointer?, rowid: Int64, text: String?, blob: Data?, fromMe: Int64, date: Int64, handle: Int64, service: String) throws {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO message (ROWID, text, attributedBody, is_from_me, date, handle_id, service) VALUES (?, ?, ?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw FixtureError.sqlite("prepare insert failed")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowid)
        if let text {
            sqlite3_bind_text(stmt, 2, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        if let blob {
            blob.withUnsafeBytes { buf in
                sqlite3_bind_blob(stmt, 3, buf.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_int64(stmt, 4, fromMe)
        sqlite3_bind_int64(stmt, 5, date)
        if handle > 0 {
            sqlite3_bind_int64(stmt, 6, handle)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        sqlite3_bind_text(stmt, 7, service, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw FixtureError.sqlite("insert message step failed")
        }
    }
}
