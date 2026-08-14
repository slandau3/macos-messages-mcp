import Foundation
@testable import MacOSMessagesMCPCore

func runLocalIPCTests() {
    runTest("temporary IPC socket paths are unique") {
        let first = LocalIPC.makeTemporarySocketPath()
        let second = LocalIPC.makeTemporarySocketPath()
        check(first != second, "each proxy invocation needs a fresh private socket path")
        check(first.contains(LocalIPC.socketPrefix), "socket path should use the private prefix")
        check(!first.contains("UUID().uuidString"), "socket path must contain the generated UUID")
        check(first.utf8.count < 104, "socket path must fit macOS sockaddr_un.sun_path")
    }
}
