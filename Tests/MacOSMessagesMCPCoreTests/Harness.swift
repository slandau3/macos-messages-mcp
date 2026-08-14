import Foundation

var harnessCheckCount = 0
var harnessFailureCount = 0

func check(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    harnessCheckCount += 1
    if !condition {
        harnessFailureCount += 1
        print("FAIL \(file):\(line): \(message)")
    }
}

func checkEqual<T: Equatable>(_ actual: T?, _ expected: T?, _ message: String = "", file: String = #fileID, line: Int = #line) {
    harnessCheckCount += 1
    if actual != expected {
        harnessFailureCount += 1
        print("FAIL \(file):\(line): expected \(String(describing: expected)) but got \(String(describing: actual)) \(message)")
    }
}

func checkNil(_ value: Any?, _ message: String = "", file: String = #fileID, line: Int = #line) {
    check(value == nil, "expected nil but got \(String(describing: value)) \(message)", file: file, line: line)
}

func checkNotNil(_ value: Any?, _ message: String = "", file: String = #fileID, line: Int = #line) {
    check(value != nil, "expected non-nil \(message)", file: file, line: line)
}

func checkThrows(_ body: @autoclosure () throws -> Void, _ message: String = "", file: String = #fileID, line: Int = #line) {
    harnessCheckCount += 1
    do {
        try body()
        harnessFailureCount += 1
        print("FAIL \(file):\(line): expected throw but completed \(message)")
    } catch {
    }
}

func runTest(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("ok - \(name)")
    } catch {
        harnessFailureCount += 1
        print("FAIL - \(name): threw \(error)")
    }
}

func harnessExit() -> Never {
    print("\(harnessCheckCount) checks, \(harnessFailureCount) failures")
    if harnessFailureCount > 0 {
        exit(1)
    }
    exit(0)
}
