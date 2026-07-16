import CryptoKit
import Foundation

struct AdModelFile: Equatable, Codable {
    let relativePath: String
    let byteCount: Int64
    let sha256: String
}

struct AdModelManifest: Equatable, Codable {
    let repository: String
    let revision: String
    let files: [AdModelFile]

    var totalByteCount: Int64 {
        files.reduce(0) { $0 + $1.byteCount }
    }

    static let qwen35FourBitV1 = AdModelManifest(
        repository: "mlx-community/Qwen3.5-4B-MLX-4bit",
        revision: "32f3e8ecf65426fc3306969496342d504bfa13f3",
        files: [
            AdModelFile(
                relativePath: "chat_template.jinja",
                byteCount: 7_756,
                sha256: "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"
            ),
            AdModelFile(
                relativePath: "config.json",
                byteCount: 3_366,
                sha256: "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa"
            ),
            AdModelFile(
                relativePath: "model.safetensors",
                byteCount: 3_034_300_695,
                sha256: "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db"
            ),
            AdModelFile(
                relativePath: "model.safetensors.index.json",
                byteCount: 101_944,
                sha256: "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a"
            ),
            AdModelFile(
                relativePath: "preprocessor_config.json",
                byteCount: 390,
                sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516"
            ),
            AdModelFile(
                relativePath: "processor_config.json",
                byteCount: 1_300,
                sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b"
            ),
            AdModelFile(
                relativePath: "tokenizer.json",
                byteCount: 19_989_343,
                sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"
            ),
            AdModelFile(
                relativePath: "tokenizer_config.json",
                byteCount: 1_139,
                sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"
            ),
            AdModelFile(
                relativePath: "video_preprocessor_config.json",
                byteCount: 385,
                sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13"
            ),
            AdModelFile(
                relativePath: "vocab.json",
                byteCount: 6_722_759,
                sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003"
            )
        ]
    )
}

enum AdModelAssetError: Error, Equatable {
    case invalidManifest
    case invalidPath(String)
    case missingFile(String)
    case byteCountMismatch(String)
    case checksumMismatch(String)
    case consentMismatch
}

enum AdModelDownloadPolicy {
    static func configuration(identifier: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.waitsForConnectivity = true
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }

    static func authorize(manifest: AdModelManifest, confirmedByteCount: Int64) throws {
        guard confirmedByteCount == manifest.totalByteCount else {
            throw AdModelAssetError.consentMismatch
        }
    }
}

final class AdModelAssetStore {
    let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        try excludeFromBackup(self.rootURL)
    }

    convenience init(artifactStore: AdRemovalArtifactStore, fileManager: FileManager = .default) throws {
        try self.init(
            rootURL: artifactStore.rootURL.appendingPathComponent("models", isDirectory: true),
            fileManager: fileManager
        )
    }

    func modelDirectory(for manifest: AdModelManifest) -> URL {
        rootURL.appendingPathComponent(manifest.revision, isDirectory: true)
    }

    func fileURL(for file: AdModelFile, manifest: AdModelManifest) throws -> URL {
        guard Self.isSafeComponent(manifest.revision), Self.isSafe(relativePath: file.relativePath) else {
            throw AdModelAssetError.invalidPath(file.relativePath)
        }
        let directory = modelDirectory(for: manifest).standardizedFileURL
        let candidate = directory.appendingPathComponent(file.relativePath).standardizedFileURL
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        guard candidate.path.hasPrefix(prefix) else {
            throw AdModelAssetError.invalidPath(file.relativePath)
        }
        return candidate
    }

    func verify(manifest: AdModelManifest) throws {
        guard !manifest.repository.isEmpty,
              Self.isSafeComponent(manifest.revision),
              !manifest.files.isEmpty,
              Set(manifest.files.map(\.relativePath)).count == manifest.files.count else {
            throw AdModelAssetError.invalidManifest
        }
        for file in manifest.files {
            guard file.byteCount > 0,
                  file.sha256.count == 64,
                  file.sha256.unicodeScalars.allSatisfy({
                      CharacterSet(charactersIn: "0123456789abcdef").contains($0)
                  }) else {
                throw AdModelAssetError.invalidManifest
            }
            let url = try fileURL(for: file, manifest: manifest)
            guard fileManager.fileExists(atPath: url.path) else {
                throw AdModelAssetError.missingFile(file.relativePath)
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? -1
            guard size == file.byteCount else {
                throw AdModelAssetError.byteCountMismatch(file.relativePath)
            }
            guard try sha256(of: url) == file.sha256 else {
                throw AdModelAssetError.checksumMismatch(file.relativePath)
            }
        }
    }

    @discardableResult
    func activate(manifest: AdModelManifest, database: PodsDatabase) throws -> URL {
        try verify(manifest: manifest)
        let checksumData = try JSONEncoder().encode(manifest.files)
        let checksumJSON = String(decoding: checksumData, as: UTF8.self)
        try database.withTransaction {
            let values: [(String, String)] = [
                ("ad_removal_model_repository", manifest.repository),
                ("ad_removal_model_revision", manifest.revision),
                ("ad_removal_model_checksums", checksumJSON),
                ("ad_removal_model_byte_count", String(manifest.totalByteCount)),
                ("ad_removal_model_download_state", "ready")
            ]
            for (key, value) in values {
                try database.execute(
                    """
                    INSERT INTO settings (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    [.text(key), .text(value)]
                )
            }
        }
        return modelDirectory(for: manifest)
    }

    func installForTesting(_ data: Data, at relativePath: String, manifest: AdModelManifest) throws {
        guard let file = manifest.files.first(where: { $0.relativePath == relativePath }) else {
            throw AdModelAssetError.invalidPath(relativePath)
        }
        let url = try fileURL(for: file, manifest: manifest)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try excludeFromBackup(url)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isSafe(relativePath: String) -> Bool {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\\") else {
            return false
        }
        return relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
        }
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}
