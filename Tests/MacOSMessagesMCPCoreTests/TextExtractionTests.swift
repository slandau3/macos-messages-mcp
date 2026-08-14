import Foundation
@testable import MacOSMessagesMCPCore

func runTextExtractionTests() {
    runTest("prefers plain text column") {
        let blob = FixtureDB.makeAttributedBodyBlob("blob text")
        checkEqual(extractMessageText(text: "plain text", attributedBody: blob), "plain text")
    }

    runTest("falls back to attributedBody") {
        let blob = FixtureDB.makeAttributedBodyBlob("Blob fallback text")
        checkEqual(extractMessageText(text: nil, attributedBody: blob), "Blob fallback text")
    }

    runTest("empty text falls back to attributedBody") {
        let blob = FixtureDB.makeAttributedBodyBlob("something")
        checkEqual(extractMessageText(text: "", attributedBody: blob), "something")
    }

    runTest("garbage blob returns nil") {
        let blob = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x03])
        checkNil(extractMessageText(text: nil, attributedBody: blob))
    }

    runTest("nil everything returns nil") {
        checkNil(extractMessageText(text: nil, attributedBody: nil))
    }

    runTest("appleDate from nanoseconds") {
        let date = appleDate(700_000_000_000_000_000)
        checkNotNil(date)
        if let date {
            check(abs(date.timeIntervalSince1970 - (700_000_000 + 978_307_200)) < 1.0, "nanosecond conversion")
        }
    }

    runTest("appleDate from seconds") {
        let date = appleDate(700_000_000)
        checkNotNil(date)
        if let date {
            check(abs(date.timeIntervalSince1970 - (700_000_000 + 978_307_200)) < 1.0, "second conversion")
        }
    }

    runTest("appleDate zero is nil") {
        checkNil(appleDate(0))
    }
}
