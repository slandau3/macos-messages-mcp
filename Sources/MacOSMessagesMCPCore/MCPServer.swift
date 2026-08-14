import Foundation

public final class MCPServer {
    public static let serverName = "macos-messages-mcp"
    public static let serverVersion = "0.1.0"
    public static let protocolVersion = "2024-11-05"
    public static let maxInputBytes = 1_048_576
    public static let maxQueryBytes = 4_096

    private let databasePath: String
    private var database: ChatDatabase?
    private let dateFormatter: ISO8601DateFormatter

    public init(databasePath: String = ChatDatabase.defaultPath) {
        self.databasePath = databasePath
        self.dateFormatter = ISO8601DateFormatter()
    }

    public func shutdown() {
        database = nil
    }

    private func db() throws -> ChatDatabase {
        if let database { return database }
        let created = try ChatDatabase(path: databasePath)
        database = created
        return created
    }

    public func handleLine(_ line: String) -> String? {
        guard let data = line.data(using: .utf8), data.count <= MCPServer.maxInputBytes else {
            return encode(errorResponse(id: NSNull(), code: -32700, message: "Parse error"))
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return encode(errorResponse(id: NSNull(), code: -32700, message: "Parse error"))
        }
        guard let object = parsed as? [String: Any] else {
            return encode(errorResponse(id: NSNull(), code: -32600, message: "Invalid request"))
        }
        guard object["jsonrpc"] as? String == "2.0" else {
            return encode(errorResponse(id: object["id"] ?? NSNull(), code: -32600, message: "Invalid request: jsonrpc must be 2.0"))
        }

        let id: Any = object["id"] ?? NSNull()
        let isNotification = object["id"] == nil
        if !isNotification && !isValidID(id) {
            return encode(errorResponse(id: NSNull(), code: -32600, message: "Invalid request: id must be a string, number, or null"))
        }

        guard let method = object["method"] as? String else {
            if isNotification { return nil }
            return encode(errorResponse(id: id, code: -32600, message: "Invalid request: missing method"))
        }

        if isNotification { return nil }

        switch method {
        case "initialize":
            return encode(resultResponse(id: id, result: [
                "protocolVersion": MCPServer.protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": MCPServer.serverName, "version": MCPServer.serverVersion],
            ]))
        case "ping":
            return encode(resultResponse(id: id, result: [String: Any]()))
        case "tools/list":
            return encode(resultResponse(id: id, result: ["tools": MCPServer.toolDefinitions]))
        case "tools/call":
            guard let params = object["params"] as? [String: Any],
                  let name = params["name"] as? String,
                  !name.isEmpty else {
                return encode(errorResponse(id: id, code: -32602, message: "Invalid params"))
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return encode(resultResponse(id: id, result: callTool(name: name, arguments: arguments)))
        default:
            return encode(errorResponse(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    private func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
        do {
            let payload: [String: Any]
            switch name {
            case "doctor":
                payload = doctorPayload()
            case "list_chats":
                let chats = try db().listChats(limit: limitArgument(arguments))
                payload = ["chats": chats.map(chatDictionary)]
            case "recent_messages":
                let messages = try db().recentMessages(limit: limitArgument(arguments))
                payload = ["messages": messages.map(messageDictionary)]
            case "search_messages":
                guard let query = arguments["query"] as? String else {
                    return toolError("missing required string argument: query")
                }
                guard query.utf8.count <= MCPServer.maxQueryBytes else {
                    return toolError("query is too long; maximum is \(MCPServer.maxQueryBytes) UTF-8 bytes")
                }
                let messages = try db().searchMessages(query: query, limit: limitArgument(arguments))
                payload = ["messages": messages.map(messageDictionary)]
            case "get_chat_messages":
                guard let chatId = (arguments["chatId"] as? NSNumber)?.int64Value ?? (arguments["chatId"] as? Int).map(Int64.init) else {
                    return toolError("missing required integer argument: chatId")
                }
                let messages = try db().chatMessages(chatId: chatId, limit: limitArgument(arguments))
                payload = ["messages": messages.map(messageDictionary)]
            case "message_stats":
                payload = statsDictionary(try db().messageStats())
            default:
                return toolError("unknown tool: \(name)")
            }
            return toolResult(payload)
        } catch {
            return toolError("The operation could not be completed. Run the doctor tool for diagnostics.")
        }
    }

    private func doctorPayload() -> [String: Any] {
        let report: DoctorReport
        if let database {
            report = database.doctor()
        } else {
            report = ChatDatabase(unopenedPath: databasePath).doctor()
        }
        var payload: [String: Any] = [
            "path": report.path,
            "fileExists": report.fileExists,
            "fileReadable": report.fileReadable,
            "opensReadOnly": report.opensReadOnly,
            "queryOnlyEnabled": report.queryOnlyEnabled,
            "schemaLooksValid": report.schemaLooksValid,
            "writesBlocked": report.writesBlocked,
            "usesPrivateSnapshot": report.usesPrivateSnapshot,
            "notes": report.notes,
        ]
        if let count = report.messageCount { payload["messageCount"] = count }
        return payload
    }

    private func chatDictionary(_ chat: ChatSummary) -> [String: Any] {
        var dict: [String: Any] = [
            "id": chat.id,
            "messageCount": chat.messageCount,
        ]
        if let identifier = chat.identifier { dict["identifier"] = identifier }
        if let displayName = chat.displayName, !displayName.isEmpty { dict["displayName"] = displayName }
        if let service = chat.serviceName { dict["service"] = service }
        if let lastActivity = chat.lastActivity { dict["lastActivity"] = dateFormatter.string(from: lastActivity) }
        return dict
    }

    private func messageDictionary(_ message: MessageRow) -> [String: Any] {
        var dict: [String: Any] = [
            "id": message.id,
            "isFromMe": message.isFromMe,
        ]
        if let chatId = message.chatId { dict["chatId"] = chatId }
        if let chatName = message.chatDisplayName, !chatName.isEmpty { dict["chatDisplayName"] = chatName }
        if let sender = message.sender { dict["sender"] = sender }
        if let date = message.date { dict["date"] = dateFormatter.string(from: date) }
        if let text = message.text { dict["text"] = text }
        if let service = message.service { dict["service"] = service }
        return dict
    }

    private func statsDictionary(_ stats: MessageStats) -> [String: Any] {
        var dict: [String: Any] = [
            "totalMessages": stats.totalMessages,
            "totalChats": stats.totalChats,
            "totalHandles": stats.totalHandles,
        ]
        if let oldest = stats.oldestMessageDate { dict["oldestMessageDate"] = dateFormatter.string(from: oldest) }
        if let newest = stats.newestMessageDate { dict["newestMessageDate"] = dateFormatter.string(from: newest) }
        return dict
    }

    private func limitArgument(_ arguments: [String: Any]) -> Int {
        let raw = (arguments["limit"] as? NSNumber)?.intValue ?? 50
        return min(max(raw, 1), 500)
    }

    private func toolResult(_ payload: [String: Any]) -> [String: Any] {
        let text: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            text = string
        } else {
            text = "{}"
        }
        return [
            "content": [["type": "text", "text": text]],
            "structuredContent": payload,
            "isError": false,
        ]
    }

    private func toolError(_ message: String) -> [String: Any] {
        [
            "content": [["type": "text", "text": message]],
            "structuredContent": ["error": message],
            "isError": true,
        ]
    }

    private func resultResponse(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func encode(_ response: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func isValidID(_ value: Any) -> Bool {
        value is String || value is NSNumber || value is NSNull
    }

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "doctor",
            "description": "Check that ~/Library/Messages/chat.db exists, is readable, opens read-only with query_only enabled, and has the expected iMessage schema. Reports what to fix (for example Full Disk Access for the app bundle) if not.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
            "readOnlyHint": true,
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
        ],
        [
            "name": "list_chats",
            "description": "List iMessage/SMS chats ordered by most recent activity, with message counts.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "description": "Maximum chats to return (1-500, default 50)"],
                ],
                "additionalProperties": false,
            ],
            "readOnlyHint": true,
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
        ],
        [
            "name": "search_messages",
            "description": "Search plain-text message bodies for a case-insensitive substring. Wildcards are escaped; messages stored only as rich text (attributedBody) are not matched.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Substring to search for"],
                    "limit": ["type": "integer", "description": "Maximum messages to return (1-500, default 50)"],
                ],
                "required": ["query"],
                "additionalProperties": false,
            ],
            "readOnlyHint": true,
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
        ],
        [
            "name": "recent_messages",
            "description": "Return the most recent messages across all chats, newest first.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "description": "Maximum messages to return (1-500, default 50)"],
                ],
                "additionalProperties": false,
            ],
            "readOnlyHint": true,
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
        ],
        [
            "name": "get_chat_messages",
            "description": "Return messages for a single chat (use list_chats to find chat ids), oldest first.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "chatId": ["type": "integer", "description": "Chat ROWID from list_chats"],
                    "limit": ["type": "integer", "description": "Maximum messages to return (1-500, default 50)"],
                ],
                "required": ["chatId"],
                "additionalProperties": false,
            ],
            "readOnlyHint": true,
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
        ],
        [
            "name": "message_stats",
            "description": "Return aggregate counts (messages, chats, handles) and the oldest/newest message dates.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
            "readOnlyHint": true,
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
        ],
    ]
}
