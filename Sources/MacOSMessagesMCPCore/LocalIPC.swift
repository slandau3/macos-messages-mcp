import Foundation
import Darwin

public enum LocalIPCError: Error, CustomStringConvertible {
    case invalidSocketPath
    case systemCall(String, Int32)
    case timedOut
    case lineTooLong

    public var description: String {
        switch self {
        case .invalidSocketPath:
            return "The local socket path is invalid."
        case let .systemCall(name, code):
            return name + " failed with errno " + String(code) + "."
        case .timedOut:
            return "The local helper did not connect in time."
        case .lineTooLong:
            return "The local handshake line is too long."
        }
    }
}

/// Small, dependency-free Unix-domain socket wrapper used only between the
/// stdio proxy and the LaunchServices-started worker in the same app bundle.
public final class LocalIPCChannel {
    public let fileDescriptor: Int32
    private var bufferedReadData = Data()
    private let closesOnDeinit: Bool

    public init(fileDescriptor: Int32, closesOnDeinit: Bool = true) {
        self.fileDescriptor = fileDescriptor
        self.closesOnDeinit = closesOnDeinit
    }

    deinit {
        if closesOnDeinit {
            Darwin.close(fileDescriptor)
        }
    }

    public func read(upTo byteCount: Int = 64 * 1024) throws -> Data? {
        if !bufferedReadData.isEmpty {
            let count = min(byteCount, bufferedReadData.count)
            let data = Data(bufferedReadData.prefix(count))
            bufferedReadData.removeFirst(count)
            return data
        }

        var bytes = [UInt8](repeating: 0, count: max(byteCount, 1))
        let result = bytes.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
        }
        if result < 0 {
            throw LocalIPCError.systemCall("read", errno)
        }
        if result == 0 { return nil }
        return Data(bytes.prefix(Int(result)))
    }

    public func readLine(maxBytes: Int) throws -> Data? {
        while true {
            if let newline = bufferedReadData.firstIndex(of: 0x0A) {
                let line = Data(bufferedReadData[..<newline])
                bufferedReadData.removeSubrange(bufferedReadData.startIndex...newline)
                if line.count > maxBytes { throw LocalIPCError.lineTooLong }
                return line
            }
            if bufferedReadData.count > maxBytes {
                throw LocalIPCError.lineTooLong
            }
            guard let chunk = try read() else {
                guard !bufferedReadData.isEmpty else { return nil }
                let line = bufferedReadData
                bufferedReadData.removeAll(keepingCapacity: false)
                if line.count > maxBytes { throw LocalIPCError.lineTooLong }
                return line
            }
            bufferedReadData.append(chunk)
        }
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let result = Darwin.write(fileDescriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw LocalIPCError.systemCall("write", errno)
                }
                if result == 0 {
                    throw LocalIPCError.systemCall("write", EPIPE)
                }
                offset += result
            }
        }
    }

    public func shutdownWrite() {
        _ = Darwin.shutdown(fileDescriptor, SHUT_WR)
    }

    public func close() {
        _ = Darwin.close(fileDescriptor)
    }
}

public enum LocalIPC {
    public static let socketPrefix = "macos-messages-mcp-"

    public static func createServer(at path: String) throws -> Int32 {
        let address = try makeAddress(path: path)
        unlink(path)
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw LocalIPCError.systemCall("socket", errno) }

        var mutableAddress = address
        let bindResult = withUnsafePointer(to: &mutableAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            Darwin.close(socketFD)
            throw LocalIPCError.systemCall("bind", code)
        }
        guard chmod(path, mode_t(0o600)) == 0 else {
            let code = errno
            Darwin.close(socketFD)
            unlink(path)
            throw LocalIPCError.systemCall("chmod", code)
        }
        guard Darwin.listen(socketFD, 1) == 0 else {
            let code = errno
            Darwin.close(socketFD)
            unlink(path)
            throw LocalIPCError.systemCall("listen", code)
        }
        return socketFD
    }

    public static func accept(serverFD: Int32, timeout: TimeInterval) throws -> Int32 {
        var descriptor = pollfd(fd: serverFD, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(max(1, min(timeout * 1000, Double(Int32.max))))
        let pollResult = Darwin.poll(&descriptor, 1, milliseconds)
        if pollResult == 0 { throw LocalIPCError.timedOut }
        if pollResult < 0 {
            if errno == EINTR { throw LocalIPCError.timedOut }
            throw LocalIPCError.systemCall("poll", errno)
        }
        let clientFD = Darwin.accept(serverFD, nil, nil)
        guard clientFD >= 0 else { throw LocalIPCError.systemCall("accept", errno) }
        return clientFD
    }

    public static func connect(to path: String, timeout: TimeInterval) throws -> Int32 {
        let address = try makeAddress(path: path)
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Int32 = ECONNREFUSED

        while Date() < deadline {
            let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard socketFD >= 0 else { throw LocalIPCError.systemCall("socket", errno) }
            var mutableAddress = address
            let result = withUnsafePointer(to: &mutableAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 { return socketFD }
            lastError = errno
            Darwin.close(socketFD)
            if lastError != ENOENT && lastError != ECONNREFUSED && lastError != EINTR {
                throw LocalIPCError.systemCall("connect", lastError)
            }
            usleep(50_000)
        }
        throw LocalIPCError.systemCall("connect", lastError)
    }

    public static func makeTemporarySocketPath() -> String {
        // macOS sockaddr_un.sun_path is only 104 bytes. The per-process
        // system temporary directory can already consume most of that budget,
        // so use the short, sticky /tmp directory with a random filename.
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let name = socketPrefix + UUID().uuidString + ".sock"
        return directory.appendingPathComponent(name).path
    }

    private static func makeAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8) + [0]
        var address = sockaddr_un()
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= pathCapacity else { throw LocalIPCError.invalidSocketPath }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            for (index, byte) in bytes.enumerated() {
                rawBuffer[index] = byte
            }
        }
        return address
    }
}
