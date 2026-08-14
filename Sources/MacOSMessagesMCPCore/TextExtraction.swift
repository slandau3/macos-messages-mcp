import Foundation

private let appleEpochOffset: TimeInterval = 978_307_200

public func appleDate(_ raw: Double) -> Date? {
    guard raw > 0 else { return nil }
    let seconds = raw > 1e12 ? raw / 1_000_000_000 : raw
    return Date(timeIntervalSince1970: seconds + appleEpochOffset)
}

public func extractMessageText(text: String?, attributedBody: Data?) -> String? {
    if let text, !text.isEmpty { return text }
    guard let blob = attributedBody else { return nil }
    return extractFromAttributedBody(blob)
}

func extractFromAttributedBody(_ data: Data) -> String? {
    let marker = [UInt8]("NSString".utf8)
    let bytes = [UInt8](data)
    guard bytes.count > marker.count else { return nil }

    var markerEnd: Int?
    var i = 0
    while i <= bytes.count - marker.count {
        var matched = true
        for j in 0..<marker.count where bytes[i + j] != marker[j] {
            matched = false
            break
        }
        if matched {
            markerEnd = i + marker.count
            break
        }
        i += 1
    }
    guard let start = markerEnd else { return nil }

    let scanLimit = min(start + 16, bytes.count)
    var cursor = start
    while cursor < scanLimit {
        let length = Int(bytes[cursor])
        if length >= 2, cursor + 1 + length <= bytes.count {
            let candidate = bytes[(cursor + 1)..<(cursor + 1 + length)]
            if let string = String(bytes: candidate, encoding: .utf8), isPrintableText(string) {
                return string
            }
        }
        cursor += 1
    }
    return nil
}

private func isPrintableText(_ string: String) -> Bool {
    guard !string.isEmpty else { return false }
    for scalar in string.unicodeScalars {
        if scalar == "\t" || scalar == "\n" || scalar == "\r" { continue }
        if scalar.value < 0x20 || scalar.value == 0x7F { return false }
    }
    return true
}
