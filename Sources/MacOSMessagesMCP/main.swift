import Foundation
import Dispatch
import Darwin
import MacOSMessagesMCPCore

let maxLineBytes = MCPServer.maxInputBytes

func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func installSignalHandlers(for server: MCPServer) -> [DispatchSourceSignal] {
    let queue = DispatchQueue(label: "local.macos.messages-mcp.shutdown")
    var sources: [DispatchSourceSignal] = []
    for signalNumber in [SIGTERM, SIGINT] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
        source.setEventHandler {
            server.shutdown()
            exit(0)
        }
        source.resume()
        sources.append(source)
    }
    return sources
}

func runProtocol(server: MCPServer, input: LocalIPCChannel, output: LocalIPCChannel) {
    let shutdownSources = installSignalHandlers(for: server)

    func writeResponse(_ response: String) -> Bool {
        do {
            try output.write(Data((response + "\n").utf8))
            return true
        } catch {
            return false
        }
    }

    func handleLineData(_ data: Data) -> Bool {
        guard !data.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D || $0 == 0x0A }) else { return true }
        guard let line = String(data: data, encoding: .utf8) else {
            return writeResponse(#"{"error":{"code":-32700,"message":"Parse error"},"id":null,"jsonrpc":"2.0"}"#)
        }
        if let response = server.handleLine(line) {
            return writeResponse(response)
        }
        return true
    }

    var buffer = Data()
    var discardingOversizedLine = false

    while true {
        let chunk: Data?
        do {
            chunk = try input.read()
        } catch {
            break
        }
        guard let chunk else { break }
        buffer.append(chunk)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = Data(buffer[..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)

            if discardingOversizedLine {
                discardingOversizedLine = false
                continue
            }
            if lineData.count > maxLineBytes {
                if !writeResponse(#"{"error":{"code":-32700,"message":"Parse error"},"id":null,"jsonrpc":"2.0"}"#) { break }
                continue
            }
            if !handleLineData(lineData) { break }
        }

        if buffer.count > maxLineBytes {
            buffer.removeAll(keepingCapacity: true)
            discardingOversizedLine = true
        }
    }

    if !discardingOversizedLine && !buffer.isEmpty && buffer.count <= maxLineBytes {
        _ = handleLineData(buffer)
    } else if buffer.count > maxLineBytes {
        _ = writeResponse(#"{"error":{"code":-32700,"message":"Parse error"},"id":null,"jsonrpc":"2.0"}"#)
    }

    server.shutdown()
    shutdownSources.forEach { $0.cancel() }
}

func argumentValue(named name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

func runWorker() {
    guard let socketPath = argumentValue(named: "--socket"),
          let token = argumentValue(named: "--token") else {
        writeError("MacOSMessagesMCP worker is missing its private channel arguments.")
        exit(1)
    }

    let workerFD: Int32
    do {
        workerFD = try LocalIPC.connect(to: socketPath, timeout: 15)
    } catch {
        writeError("MacOSMessagesMCP worker could not connect to its private channel.")
        exit(1)
    }

    let channel = LocalIPCChannel(fileDescriptor: workerFD)
    do {
        try channel.write(Data("MACOS_MESSAGES_MCP/1 \(token)\n".utf8))
        guard let response = try channel.readLine(maxBytes: 64), response == Data("OK".utf8) else {
            writeError("MacOSMessagesMCP worker failed private-channel authentication.")
            exit(1)
        }
    } catch {
        writeError("MacOSMessagesMCP worker failed private-channel authentication.")
        exit(1)
    }

    let server = MCPServer()
    runProtocol(server: server, input: channel, output: channel)
}

let isWorker = CommandLine.arguments.contains("--macos-messages-worker")
let server = MCPServer()
if isWorker {
    runWorker()
} else {
    let input = LocalIPCChannel(fileDescriptor: STDIN_FILENO, closesOnDeinit: false)
    let output = LocalIPCChannel(fileDescriptor: STDOUT_FILENO, closesOnDeinit: false)
    runProtocol(server: server, input: input, output: output)
}
