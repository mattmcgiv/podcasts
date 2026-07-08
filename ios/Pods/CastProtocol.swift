import Foundation

/// Shared constants for the Pods phone ↔ Mac speaker control channel.
/// Protocol is newline-delimited JSON over TCP, discovered via Bonjour.
enum CastProtocol {
    static let bonjourType = "_pods-speaker._tcp"
    static let version = 1
    static let tokenDefaultsKey = "pods.cast.pairingToken"

    static func encodeLine(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              var line = String(data: data, encoding: .utf8) else {
            return nil
        }
        line.append("\n")
        return line.data(using: .utf8)
    }

    static func parseLines(from buffer: inout Data) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        while let range = buffer.range(of: Data([0x0A])) {
            let slice = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            if slice.isEmpty { continue }
            if let obj = try? JSONSerialization.jsonObject(with: slice) as? [String: Any] {
                messages.append(obj)
            }
        }
        return messages
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    static func floatValue(_ value: Any?) -> Float? {
        if let value = value as? Float { return value }
        if let value = value as? Double { return Float(value) }
        if let value = value as? NSNumber { return value.floatValue }
        return nil
    }

    static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    static func normalizedRate(_ value: Float) -> Float {
        value.isFinite && value > 0 ? value : 1
    }
}

struct CastStatus: Equatable {
    var available: Bool = false
    var connected: Bool = false
    var name: String?
    var error: String?

    var jsObject: [String: Any] {
        var obj: [String: Any] = [
            "available": available,
            "connected": connected,
        ]
        if let name { obj["name"] = name }
        if let error { obj["error"] = error }
        return obj
    }
}
