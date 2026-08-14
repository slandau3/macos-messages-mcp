import Foundation
@testable import MacOSMessagesMCPCore

private func send(_ server: MCPServer, _ body: String) -> [String: Any]? {
    guard let line = server.handleLine(body) else { return nil }
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        check(false, "response is not a JSON object: \(line)")
        return nil
    }
    return obj
}

private func sendTool(_ server: MCPServer, _ id: Int, _ name: String, _ arguments: [String: Any] = [:]) -> [String: Any]? {
    let request: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": ["name": name, "arguments": arguments],
    ]
    let data = try! JSONSerialization.data(withJSONObject: request)
    return send(server, String(data: data, encoding: .utf8)!)
}

private func toolResultText(_ response: [String: Any]?) -> String? {
    guard let result = response?["result"] as? [String: Any],
          let content = result["content"] as? [[String: Any]],
          let first = content.first else { return nil }
    return first["text"] as? String
}

private func toolResultJSON(_ response: [String: Any]?) -> Any? {
    guard let text = toolResultText(response),
          let data = text.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

func runMCPServerTests() {
    runTest("shutdown releases a cached WAL snapshot") {
        let fixture = try FixtureDB(walMode: true)
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let namesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: tempURL.path)
            .filter { $0.hasPrefix("macos-messages-snapshot-") })
        let server = MCPServer(databasePath: fixture.path)
        _ = sendTool(server, 0, "recent_messages", ["limit": 1])
        let namesDuring = Set(try FileManager.default.contentsOfDirectory(atPath: tempURL.path)
            .filter { $0.hasPrefix("macos-messages-snapshot-") })
        checkEqual(namesDuring.subtracting(namesBefore).count, 1)
        server.shutdown()
        let namesAfter = Set(try FileManager.default.contentsOfDirectory(atPath: tempURL.path)
            .filter { $0.hasPrefix("macos-messages-snapshot-") })
        checkEqual(namesAfter, namesBefore)
    }

    runTest("initialize returns protocol version and server info") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let response = send(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        checkEqual(response?["jsonrpc"] as? String, "2.0")
        checkEqual(response?["id"] as? Int, 1)
        let result = response?["result"] as? [String: Any]
        checkNotNil(result?["protocolVersion"])
        checkEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "macos-messages-mcp")
        checkNotNil((result?["capabilities"] as? [String: Any])?["tools"])
    }

    runTest("tools/list contains exactly the six v1 tools") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let response = send(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let result = response?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]] ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        checkEqual(names, ["doctor", "list_chats", "search_messages", "recent_messages", "get_chat_messages", "message_stats"])
        for tool in tools {
            checkNotNil(tool["description"], "tool description")
            checkNotNil(tool["inputSchema"], "tool inputSchema")
        }
    }

    runTest("ping") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let response = send(server, #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)
        checkEqual(response?["id"] as? Int, 3)
        checkNotNil(response?["result"])
    }

    runTest("notification gets no response") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        checkNil(server.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }

    runTest("unknown method returns -32601") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let response = send(server, #"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#)
        checkEqual((response?["error"] as? [String: Any])?["code"] as? Int, -32601)
        checkEqual(response?["id"] as? Int, 4)
    }

    runTest("invalid JSON returns -32700") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let response = send(server, "this is not json")
        checkEqual((response?["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    runTest("wrong JSON-RPC version returns invalid request") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let response = send(server, #"{"jsonrpc":"1.0","id":4,"method":"ping"}"#)
        checkEqual((response?["error"] as? [String: Any])?["code"] as? Int, -32600)
    }

    runTest("non-object JSON returns invalid request") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let response = send(server, "[]")
        checkEqual((response?["error"] as? [String: Any])?["code"] as? Int, -32600)
    }

    runTest("search query length is bounded") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let response = sendTool(server, 14, "search_messages", ["query": String(repeating: "x", count: 5000)])
        checkEqual((response?["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    runTest("tools are marked read-only and return structured content") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let listResponse = send(server, #"{"jsonrpc":"2.0","id":15,"method":"tools/list"}"#)
        let tools = ((listResponse?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        check(tools.allSatisfy { ($0["readOnlyHint"] as? Bool) == true }, "all tools should be read-only")

        let toolResponse = sendTool(server, 16, "message_stats")
        let result = toolResponse?["result"] as? [String: Any]
        checkNotNil(result?["structuredContent"], "structured content")
    }

    runTest("unknown tool returns isError result") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let response = sendTool(server, 5, "drop_everything")
        checkEqual((response?["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    runTest("doctor tool") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let response = sendTool(server, 6, "doctor")
        let json = toolResultJSON(response) as? [String: Any]
        checkEqual(json?["fileExists"] as? Bool, true)
        checkEqual(json?["opensReadOnly"] as? Bool, true)
        checkEqual(json?["messageCount"] as? Int, 4)
    }

    runTest("list_chats tool") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let response = sendTool(server, 7, "list_chats", ["limit": 10])
        let json = toolResultJSON(response) as? [String: Any]
        let chats = json?["chats"] as? [[String: Any]] ?? []
        checkEqual(chats.count, 2)
        checkEqual(chats.first?["displayName"] as? String, "Family Group")
    }

    runTest("recent_messages tool") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let response = sendTool(server, 8, "recent_messages", ["limit": 2])
        let json = toolResultJSON(response) as? [String: Any]
        let messages = json?["messages"] as? [[String: Any]] ?? []
        checkEqual(messages.count, 2)
        checkEqual(messages.first?["text"] as? String, "dinner at 7?")
    }

    runTest("search_messages tool") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let response = sendTool(server, 9, "search_messages", ["query": "Hello"])
        let json = toolResultJSON(response) as? [String: Any]
        let messages = json?["messages"] as? [[String: Any]] ?? []
        checkEqual(messages.count, 1)
        checkEqual(messages.first?["text"] as? String, "Hello Bob")
    }

    runTest("search_messages requires query") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let response = sendTool(server, 10, "search_messages", [:])
        checkEqual((response?["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    runTest("get_chat_messages tool") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let response = sendTool(server, 11, "get_chat_messages", ["chatId": 1, "limit": 10])
        let json = toolResultJSON(response) as? [String: Any]
        let messages = json?["messages"] as? [[String: Any]] ?? []
        checkEqual(messages.count, 3)
        checkEqual(messages.last?["text"] as? String, "Blob fallback text")
    }

    runTest("get_chat_messages requires chatId") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let response = sendTool(server, 12, "get_chat_messages", [:])
        checkEqual((response?["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    runTest("message_stats tool") {
        let fixture = try FixtureDB()
        let server = MCPServer(databasePath: fixture.path)
        let response = sendTool(server, 13, "message_stats")
        let json = toolResultJSON(response) as? [String: Any]
        checkEqual(json?["totalMessages"] as? Int, 4)
        checkEqual(json?["totalChats"] as? Int, 2)
    }
}
