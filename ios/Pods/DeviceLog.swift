import Foundation

/// Small on-device files the Mac reads back with `devicectl device copy from`
/// to check that an install works. Nothing here leaves the phone on its own.
enum DeviceLog {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Pods", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static let queue = DispatchQueue(label: "dev.mcgiv.pods.device-log")
    private static let logURL = directory.appendingPathComponent("device.log")
    private static let maxBytes = 256 * 1024

    static func write(_ line: String) {
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        queue.async {
            if let size = try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
                try? FileManager.default.removeItem(at: logURL)
            }
            guard let data = stamped.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    static func writeStatus(_ status: [String: Any]) {
        queue.async {
            guard JSONSerialization.isValidJSONObject(status),
                  let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
            else { return }
            try? data.write(to: directory.appendingPathComponent("device-status.json"), options: .atomic)
        }
    }
}
