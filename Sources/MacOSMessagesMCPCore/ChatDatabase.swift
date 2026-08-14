import Foundation
import SQLite3

public enum ChatDatabaseError: Error, CustomStringConvertible {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case writeRejected(String)
    case snapshotFailed(String)

    public var description: String {
        switch self {
        case .openFailed(let message): return "failed to open database read-only: \(message)"
        case .prepareFailed(let message): return "failed to prepare statement: \(message)"
        case .stepFailed(let message): return "query failed: \(message)"
        case .writeRejected(let message): return "write rejected: \(message)"
        case .snapshotFailed(let message): return "failed to create private database snapshot: \(message)"
        }
    }
}

public struct ChatSummary {
    public let id: Int64
    public let identifier: String?
    public let displayName: String?
    public let serviceName: String?
    public let lastActivity: Date?
    public let messageCount: Int
}

public struct MessageRow {
    public let id: Int64
    public let chatId: Int64?
    public let chatDisplayName: String?
    public let sender: String?
    public let isFromMe: Bool
    public let date: Date?
    public let text: String?
    public let service: String?
}

public struct MessageStats {
    public let totalMessages: Int
    public let totalChats: Int
    public let totalHandles: Int
    public let oldestMessageDate: Date?
    public let newestMessageDate: Date?
}

public struct DoctorReport {
    public let path: String
    public let fileExists: Bool
    public let fileReadable: Bool
    public let opensReadOnly: Bool
    public let queryOnlyEnabled: Bool
    public let schemaLooksValid: Bool
    public let writesBlocked: Bool
    public let usesPrivateSnapshot: Bool
    public let messageCount: Int?
    public let notes: [String]
}

public final class ChatDatabase {
    public static let maxSearchQueryBytes = 4_096

    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db").path
    }

    public let path: String
    private var handle: OpaquePointer?
    private var snapshotDirectory: URL?

    public init(path: String = ChatDatabase.defaultPath) throws {
        self.path = path
        try connect()
    }

    public init(unopenedPath: String) {
        self.path = unopenedPath
    }

    public var hasPrivateSnapshot: Bool { snapshotDirectory != nil }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
        if let snapshotDirectory {
            try? FileManager.default.removeItem(at: snapshotDirectory)
        }
    }

    private struct FileState: Equatable {
        let exists: Bool
        let size: UInt64
        let inode: UInt64
        let modificationTime: TimeInterval
    }

    private struct OpenTarget {
        let path: String
        let immutable: Bool
    }

    private func connect() throws {
        guard handle == nil else { return }
        let target = try prepareOpenTarget()
        var newHandle: OpaquePointer?
        var flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        var sqlitePath = target.path
        if target.immutable {
            flags |= SQLITE_OPEN_URI
            sqlitePath = URL(fileURLWithPath: target.path).absoluteString + "?immutable=1"
        }

        let rc = sqlite3_open_v2(sqlitePath, &newHandle, flags, nil)
        guard rc == SQLITE_OK, let newHandle else {
            let message = newHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(rc)"
            if let newHandle { sqlite3_close_v2(newHandle) }
            cleanupSnapshot()
            throw ChatDatabaseError.openFailed(message)
        }

        do {
            guard sqlite3_db_readonly(newHandle, nil) == 1 else {
                throw ChatDatabaseError.openFailed("SQLite did not report a read-only connection")
            }
            sqlite3_busy_timeout(newHandle, 2000)
            try execChecked(newHandle, "PRAGMA query_only = ON")
            try execChecked(newHandle, "PRAGMA temp_store = MEMORY")
            handle = newHandle
            let queryOnly = try withStatement("PRAGMA query_only") { Int(sqlite3_column_int64($0, 0)) }
            guard queryOnly.first == 1 else {
                throw ChatDatabaseError.openFailed("SQLite query_only could not be enabled")
            }
        } catch {
            sqlite3_close_v2(newHandle)
            handle = nil
            cleanupSnapshot()
            throw error
        }
    }

    private func prepareOpenTarget() throws -> OpenTarget {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            throw ChatDatabaseError.openFailed("database file does not exist")
        }

        let walPath = path + "-wal"
        let shmPath = path + "-shm"
        if fileManager.fileExists(atPath: walPath) || fileManager.fileExists(atPath: shmPath) {
            let directory = try makePrivateSnapshot()
            snapshotDirectory = directory
            return OpenTarget(path: directory.appendingPathComponent("chat.db").path, immutable: false)
        }

        // immutable=1 prevents SQLite from creating WAL sidecars in the protected
        // Messages directory if a writer starts after this process opens the file.
        return OpenTarget(path: path, immutable: true)
    }

    private func makePrivateSnapshot() throws -> URL {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
        let sourceSuffixes = ["", "-wal", "-shm"]

        for _ in 0..<3 {
            let before = sourceSuffixes.reduce(into: [String: FileState]()) { result, suffix in
                result[suffix] = fileState(path + suffix)
            }
            guard before[""]?.exists == true else {
                throw ChatDatabaseError.snapshotFailed("chat.db disappeared before it could be copied")
            }

            let directory = temporaryRoot.appendingPathComponent("macos-messages-snapshot-\(UUID().uuidString)", isDirectory: true)
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                for suffix in sourceSuffixes {
                    let source = path + suffix
                    guard fileManager.fileExists(atPath: source) else { continue }
                    let destination = directory.appendingPathComponent("chat.db\(suffix)")
                    try fileManager.copyItem(atPath: source, toPath: destination.path)
                }

                let after = sourceSuffixes.reduce(into: [String: FileState]()) { result, suffix in
                    result[suffix] = fileState(path + suffix)
                }
                if before == after {
                    return directory
                }
                try? fileManager.removeItem(at: directory)
            } catch {
                try? fileManager.removeItem(at: directory)
                if !fileManager.fileExists(atPath: path) {
                    throw ChatDatabaseError.snapshotFailed("chat.db disappeared while it was being copied")
                }
            }
        }

        throw ChatDatabaseError.snapshotFailed("Messages changed while the private snapshot was being created")
    }

    private func fileState(_ path: String) -> FileState {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return FileState(exists: false, size: 0, inode: 0, modificationTime: 0)
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let modificationTime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return FileState(exists: true, size: size, inode: inode, modificationTime: modificationTime)
    }

    private func cleanupSnapshot() {
        if let snapshotDirectory {
            try? FileManager.default.removeItem(at: snapshotDirectory)
            self.snapshotDirectory = nil
        }
    }

    private func connection() throws -> OpaquePointer {
        if let handle { return handle }
        try connect()
        guard let handle else { throw ChatDatabaseError.openFailed("no connection") }
        return handle
    }

    func executeWrite(_ sql: String) throws {
        let db = try connection()
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &error)
        let message = error.map { String(cString: $0) } ?? "sqlite error \(rc)"
        sqlite3_free(error)
        guard rc == SQLITE_OK else { throw ChatDatabaseError.writeRejected(message) }
    }

    private func execChecked(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &error)
        let message = error.map { String(cString: $0) } ?? "sqlite error \(rc)"
        sqlite3_free(error)
        guard rc == SQLITE_OK else { throw ChatDatabaseError.openFailed(message) }
    }

    private func withStatement<T>(
        _ sql: String,
        bind: (OpaquePointer) throws -> Void = { _ in },
        row: (OpaquePointer) -> T
    ) throws -> [T] {
        let db = try connection()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ChatDatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        var results: [T] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                results.append(row(statement))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw ChatDatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
        return results
    }

    private func bindInt64(_ statement: OpaquePointer, _ index: Int32, _ value: Int64) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw ChatDatabaseError.prepareFailed("failed to bind integer argument")
        }
    }

    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw ChatDatabaseError.prepareFailed("failed to bind text argument")
        }
    }

    public func listChats(limit: Int) throws -> [ChatSummary] {
        let sql = """
        SELECT c.ROWID, c.chat_identifier, c.display_name, c.service_name,
               (SELECT MAX(m.date) FROM chat_message_join cmj
                JOIN message m ON m.ROWID = cmj.message_id
                WHERE cmj.chat_id = c.ROWID) AS last_date,
               (SELECT COUNT(*) FROM chat_message_join cmj
                WHERE cmj.chat_id = c.ROWID) AS msg_count
        FROM chat c
        ORDER BY last_date DESC
        LIMIT ?
        """
        return try withStatement(sql, bind: { try bindInt64($0, 1, Int64(limit)) }) { statement in
            ChatSummary(
                id: sqlite3_column_int64(statement, 0),
                identifier: columnText(statement, 1),
                displayName: columnText(statement, 2),
                serviceName: columnText(statement, 3),
                lastActivity: appleDate(sqlite3_column_double(statement, 4)),
                messageCount: Int(sqlite3_column_int64(statement, 5))
            )
        }
    }

    public func recentMessages(limit: Int) throws -> [MessageRow] {
        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, m.date,
               h.id AS sender, c.ROWID AS chat_id, c.display_name, m.service
        FROM message m
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        ORDER BY m.date DESC
        LIMIT ?
        """
        return try withStatement(sql, bind: { try bindInt64($0, 1, Int64(limit)) }, row: messageFromRow)
    }

    public func searchMessages(query: String, limit: Int) throws -> [MessageRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.utf8.count <= ChatDatabase.maxSearchQueryBytes else {
            throw ChatDatabaseError.prepareFailed("search query is too long")
        }
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, m.date,
               h.id AS sender, c.ROWID AS chat_id, c.display_name, m.service
        FROM message m
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE m.text LIKE ? ESCAPE '\\'
        ORDER BY m.date DESC
        LIMIT ?
        """
        return try withStatement(sql, bind: { statement in
            try bindText(statement, 1, pattern)
            try bindInt64(statement, 2, Int64(limit))
        }, row: messageFromRow)
    }

    public func chatMessages(chatId: Int64, limit: Int) throws -> [MessageRow] {
        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, m.date,
               h.id AS sender, c.ROWID AS chat_id, c.display_name, m.service
        FROM message m
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE cmj.chat_id = ?
        ORDER BY m.date ASC
        LIMIT ?
        """
        return try withStatement(sql, bind: { statement in
            try bindInt64(statement, 1, chatId)
            try bindInt64(statement, 2, Int64(limit))
        }, row: messageFromRow)
    }

    public func messageStats() throws -> MessageStats {
        let rows = try withStatement("""
        SELECT (SELECT COUNT(*) FROM message),
               (SELECT COUNT(*) FROM chat),
               (SELECT COUNT(*) FROM handle),
               (SELECT MIN(m.date) FROM message m),
               (SELECT MAX(m.date) FROM message m)
        """) { statement in
            MessageStats(
                totalMessages: Int(sqlite3_column_int64(statement, 0)),
                totalChats: Int(sqlite3_column_int64(statement, 1)),
                totalHandles: Int(sqlite3_column_int64(statement, 2)),
                oldestMessageDate: appleDate(sqlite3_column_double(statement, 3)),
                newestMessageDate: appleDate(sqlite3_column_double(statement, 4))
            )
        }
        guard let stats = rows.first else {
            throw ChatDatabaseError.stepFailed("stats query returned no rows")
        }
        return stats
    }

    public func doctor() -> DoctorReport {
        var notes: [String] = []
        let fileExists = FileManager.default.fileExists(atPath: path)
        let fileReadable = access(path, R_OK) == 0
        if !fileExists {
            notes.append("chat.db not found at \(path)")
        } else if !fileReadable {
            notes.append("chat.db is not readable by this process; grant Full Disk Access to the MacOSMessagesMCP.app bundle only")
        }

        var opensReadOnly = false
        var queryOnlyEnabled = false
        var schemaLooksValid = false
        var writesBlocked = false
        var messageCount: Int?

        do {
            _ = try connection()
            opensReadOnly = true

            let pragma = try withStatement("PRAGMA query_only") { Int(sqlite3_column_int64($0, 0)) }
            queryOnlyEnabled = pragma.first == 1

            let tables = try withStatement("SELECT name FROM sqlite_master WHERE type = 'table'") {
                columnText($0, 0) ?? ""
            }
            let required: Set<String> = ["chat", "message", "handle", "chat_message_join"]
            schemaLooksValid = required.isSubset(of: Set(tables))
            if !schemaLooksValid {
                notes.append("database does not look like an iMessage chat.db (missing chat/message/handle/chat_message_join tables)")
            }

            writesBlocked = writeProbeIsBlocked()
            if !writesBlocked {
                notes.append("WARNING: database accepted a write; connection is not read-only")
            }

            if hasPrivateSnapshot {
                notes.append("using a private temporary snapshot because the source database has WAL sidecars; the source Messages files are not opened directly")
            }

            if schemaLooksValid {
                messageCount = try withStatement("SELECT COUNT(*) FROM message") { Int(sqlite3_column_int64($0, 0)) }.first
            }
        } catch {
            if fileExists && fileReadable {
                notes.append("could not open chat.db read-only; this usually means the database changed during snapshot or the schema is unsupported")
            } else {
                notes.append("could not open chat.db read-only: access is unavailable")
            }
        }

        return DoctorReport(
            path: path,
            fileExists: fileExists,
            fileReadable: fileReadable,
            opensReadOnly: opensReadOnly,
            queryOnlyEnabled: queryOnlyEnabled,
            schemaLooksValid: schemaLooksValid,
            writesBlocked: writesBlocked,
            usesPrivateSnapshot: hasPrivateSnapshot,
            messageCount: messageCount,
            notes: notes
        )
    }

    private func writeProbeIsBlocked() -> Bool {
        guard let db = try? connection() else { return false }
        var beginError: UnsafeMutablePointer<CChar>?
        let beginRC = sqlite3_exec(db, "BEGIN", nil, nil, &beginError)
        sqlite3_free(beginError)
        guard beginRC == SQLITE_OK else { return false }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }

        let tableName = "macos_messages_write_probe_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, "CREATE TABLE \(tableName) (x INTEGER)", nil, nil, &error)
        sqlite3_free(error)
        if rc == SQLITE_OK { return false }
        let code = sqlite3_errcode(db)
        return code == SQLITE_READONLY || code == SQLITE_AUTH || code == SQLITE_PERM
    }

    private func messageFromRow(_ statement: OpaquePointer) -> MessageRow {
        MessageRow(
            id: sqlite3_column_int64(statement, 0),
            chatId: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 6),
            chatDisplayName: columnText(statement, 7),
            sender: columnText(statement, 5),
            isFromMe: sqlite3_column_int(statement, 3) != 0,
            date: appleDate(sqlite3_column_double(statement, 4)),
            text: extractMessageText(text: columnText(statement, 1), attributedBody: columnBlob(statement, 2)),
            service: columnText(statement, 8)
        )
    }
}

let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let pointer = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: pointer)
}

func columnBlob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let pointer = sqlite3_column_blob(statement, index) else { return nil }
    let length = Int(sqlite3_column_bytes(statement, index))
    guard length > 0 else { return nil }
    return Data(bytes: pointer, count: length)
}
