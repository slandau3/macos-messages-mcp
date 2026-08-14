import Foundation
import Darwin
import MacOSMessagesMCPCore

let appBundleURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let socketPath = LocalIPC.makeTemporarySocketPath()
let token = UUID().uuidString
let serverFD: Int32

do {
    serverFD = try LocalIPC.createServer(at: socketPath)
} catch {
    FileHandle.standardError.write(Data("MacOSMessagesMCP proxy could not create its private channel.\n".utf8))
    exit(1)
}

defer {
    Darwin.close(serverFD)
    unlink(socketPath)
}

let launch = Process()
launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
launch.arguments = [
    "-n",
    "-a",
    appBundleURL.path,
    "--args",
    "--macos-messages-worker",
    "--socket",
    socketPath,
    "--token",
    token,
]

do {
    try launch.run()
} catch {
    FileHandle.standardError.write(Data("MacOSMessagesMCP proxy could not launch its background worker.\n".utf8))
    exit(1)
}

let workerFD: Int32
do {
    workerFD = try LocalIPC.accept(serverFD: serverFD, timeout: 15)
} catch {
    FileHandle.standardError.write(Data("MacOSMessagesMCP background worker did not connect.\n".utf8))
    exit(1)
}

let channel = LocalIPCChannel(fileDescriptor: workerFD)
let expectedHandshake = Data("MACOS_MESSAGES_MCP/1 \(token)".utf8)
do {
    guard let handshake = try channel.readLine(maxBytes: 512), handshake == expectedHandshake else {
        throw LocalIPCError.systemCall("authentication", EACCES)
    }
    try channel.write(Data("OK\n".utf8))
} catch {
    FileHandle.standardError.write(Data("MacOSMessagesMCP background worker failed local authentication.\n".utf8))
    exit(1)
}

let responseQueue = DispatchQueue(label: "local.macos.messages-mcp.proxy.responses")
let responseGroup = DispatchGroup()
responseGroup.enter()
responseQueue.async {
    defer { responseGroup.leave() }
    let output = LocalIPCChannel(fileDescriptor: STDOUT_FILENO, closesOnDeinit: false)
    do {
        while let chunk = try channel.read() {
            try output.write(chunk)
        }
    } catch {
        // The MCP client closed the pipe or the worker exited. There is no
        // useful response left for the proxy to emit.
    }
}

let input = LocalIPCChannel(fileDescriptor: STDIN_FILENO, closesOnDeinit: false)
do {
    while let chunk = try input.read() {
        try channel.write(chunk)
    }
} catch {
    // Closing the client side is the normal way to stop an on-demand worker.
}
channel.shutdownWrite()
responseGroup.wait()
