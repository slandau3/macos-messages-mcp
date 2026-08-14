import Foundation
@testable import MacOSMessagesMCPCore

func runChatDatabaseTests() {
    runTest("opens read-only and rejects writes") {
        let fixture = try FixtureDB()
        let db = try ChatDatabase(path: fixture.path)
        checkThrows(try db.executeWrite("INSERT INTO chat (ROWID) VALUES (999)"), "write must be rejected")
    }

    runTest("WAL reads do not modify source database sidecars") {
        let fixture = try FixtureDB(walMode: true)
        let sourcePaths = [fixture.path, fixture.path + "-wal", fixture.path + "-shm"]
        let before = try sourcePaths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }

        do {
            let db = try ChatDatabase(path: fixture.path)
            checkEqual(try db.recentMessages(limit: 1).count, 1)
        }

        let after = try sourcePaths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        checkEqual(after, before, "opening and querying must not alter chat.db, chat.db-wal, or chat.db-shm")
    }

    runTest("WAL private snapshot is removed when database closes") {
        let fixture = try FixtureDB(walMode: true)
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let snapshotNames: () throws -> Set<String> = {
            let names = try FileManager.default.contentsOfDirectory(atPath: tempURL.path)
            return Set(names.filter { $0.hasPrefix("macos-messages-snapshot-") })
        }
        let before = try snapshotNames()

        do {
            let db = try ChatDatabase(path: fixture.path)
            _ = try db.recentMessages(limit: 1)
            checkEqual(try snapshotNames().subtracting(before).count, 1, "WAL reads must use one private snapshot")
        }

        checkEqual(try snapshotNames(), before, "private snapshot must be deleted on close")
    }

    runTest("listChats returns chats with last activity and counts") {
        let fixture = try FixtureDB()
        let db = try ChatDatabase(path: fixture.path)
        let chats = try db.listChats(limit: 50)
        checkEqual(chats.count, 2)
        checkEqual(chats[0].id, 2)
        checkEqual(chats[0].displayName, "Family Group")
        checkEqual(chats[0].messageCount, 1)
        checkEqual(chats[1].id, 1)
        checkEqual(chats[1].messageCount, 3)
        checkNotNil(chats[0].lastActivity)
    }

    runTest("listChats respects limit") {
        let fixture = try FixtureDB()
        let db = try ChatDatabase(path: fixture.path)
        let chats = try db.listChats(limit: 1)
        checkEqual(chats.count, 1)
        checkEqual(chats[0].id, 2)
    }

    runTest("recentMessages ordered newest first") {
        let fixture = try FixtureDB()
        let db = try ChatDatabase(path: fixture.path)
        let messages = try db.recentMessages(limit: 50)
        checkEqual(messages.count, 4)
        checkEqual(messages[0].id, 4)
        checkEqual(messages[0].text, "dinner at 7?")
        checkEqual(messages[0].sender, "+15551234567")
        checkEqual(messages[0].chatId, 2)
        checkEqual(messages[3].id, 1)
    }

    runTest("recentMessages falls back to attributedBody") {
        let fixture = try FixtureDB()
        let db = try ChatDatabase(path: fixture.path)
        let messages = try db.recentMessages(limit: 50)
        let blobMessage = messages.first { $0.id == 3 }
        checkEqual(blobMessage?.text, "Blob fallback text")
    }

    runTest("searchMessages finds matching rows") {
        let fixture = try FixtureDB()
        let db = try ChatDatabase(path: fixture.path)
        let results = try db.searchMessages(query: "dinner", limit: 50)
        checkEqual(results.count, 1)
        checkEqual(results[0].id, 4)
    }

    runTest("searchMessages escapes LIKE wildcards") {
        let fixture = try FixtureDB()
        let db = try ChatDatabase(path: fixture.path)
        checkEqual(try db.searchMessages(query: "%", limit: 50).count, 0)
        checkEqual(try db.searchMessages(query: "_", limit: 50).count, 0)
    }

    runTest("searchMessages empty query returns nothing") {
        let fixture = try FixtureDB()
        let db = try ChatDatabase(path: fixture.path)
        checkEqual(try db.searchMessages(query: "", limit: 50).count, 0)
    }

    runTest("chatMessages returns chat rows oldest first") {
        let fixture = try FixtureDB()
        let db = try ChatDatabase(path: fixture.path)
        let messages = try db.chatMessages(chatId: 1, limit: 50)
        checkEqual(messages.count, 3)
        checkEqual(messages.map(\.id), [1, 2, 3])
        checkEqual(messages[1].isFromMe, true)
        checkNil(messages[1].sender)
    }

    runTest("chatMessages unknown chat returns empty") {
        let fixture = try FixtureDB()
        let db = try ChatDatabase(path: fixture.path)
        checkEqual(try db.chatMessages(chatId: 4242, limit: 50).count, 0)
    }

    runTest("messageStats") {
        let fixture = try FixtureDB()
        let db = try ChatDatabase(path: fixture.path)
        let stats = try db.messageStats()
        checkEqual(stats.totalMessages, 4)
        checkEqual(stats.totalChats, 2)
        checkEqual(stats.totalHandles, 2)
        checkNotNil(stats.oldestMessageDate)
        checkNotNil(stats.newestMessageDate)
        if let oldest = stats.oldestMessageDate, let newest = stats.newestMessageDate {
            check(oldest < newest, "oldest should be before newest")
        }
    }

    runTest("doctor reports healthy fixture") {
        let fixture = try FixtureDB()
        let db = try ChatDatabase(path: fixture.path)
        let report = db.doctor()
        check(report.fileExists, "fileExists")
        check(report.fileReadable, "fileReadable")
        check(report.opensReadOnly, "opensReadOnly")
        check(report.queryOnlyEnabled, "queryOnlyEnabled")
        check(report.schemaLooksValid, "schemaLooksValid")
        checkEqual(report.messageCount, 4)
        check(report.writesBlocked, "writesBlocked")
    }

    runTest("doctor reports missing database") {
        let db = ChatDatabase(unopenedPath: NSTemporaryDirectory() + "/does-not-exist-\(UUID().uuidString).db")
        let report = db.doctor()
        check(!report.fileExists, "fileExists should be false")
        check(!report.opensReadOnly, "opensReadOnly should be false")
    }

    runTest("apple date conversion through queries") {
        let fixture = try FixtureDB()
        let db = try ChatDatabase(path: fixture.path)
        let messages = try db.recentMessages(limit: 1)
        guard let date = messages[0].date else {
            check(false, "expected date")
            return
        }
        check(abs(date.timeIntervalSince1970 - (700_000_300 + 978_307_200)) < 1.0, "date conversion")
    }
}
