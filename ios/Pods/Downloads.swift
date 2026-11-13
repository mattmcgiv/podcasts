import CryptoKit
import Foundation
import Observation
import UIKit

/// Keeps processed episode files on the phone. Every 1 MiB chunk is checked
/// against the Mac's manifest before it is appended, and a partial file resumes
/// from its last verified chunk.
@MainActor @Observable
final class Downloads {
    static let shared = Downloads()

    struct Progress: Equatable { var received: Int; var total: Int }

    /// Hashes with a complete, verified file on disk.
    private(set) var complete: Set<String> = []
    private(set) var progress: [Int: Progress] = [:]
    private(set) var errors: [Int: String] = [:]
    /// Why the automatic queue is not running, when it is not.
    private(set) var notice: String?
    private(set) var usedBytes = 0

    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var requested: [Int] = []
    @ObservationIgnored private var again = false
    @ObservationIgnored var protectedHash: String?
    @ObservationIgnored private let client = MacClient.shared

    static let directory: URL = {
        var url = DeviceLog.directory.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Episodes can always be fetched again from the Mac; keep them out of backups.
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    init() { scan() }

    static func fileURL(_ manifest: Manifest) -> URL { directory.appendingPathComponent("\(manifest.hash).\(manifest.fileExtension)") }
    private static func partURL(_ manifest: Manifest) -> URL { directory.appendingPathComponent("\(manifest.hash).part") }

    func isDownloaded(_ episode: Episode) -> Bool { episode.manifest.map { complete.contains($0.hash) } ?? false }
    func fileURL(for episode: Episode) -> URL? {
        guard let manifest = episode.manifest, complete.contains(manifest.hash) else { return nil }
        return Self.fileURL(manifest)
    }

    private func scan() {
        var found = Set<String>(), bytes = 0
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for file in files {
            bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if file.pathExtension != "part" { found.insert(file.deletingPathExtension().lastPathComponent) }
        }
        complete = found
        usedBytes = bytes
    }

    // MARK: Queue

    /// Episodes the automatic queue wants, in Listen order, within the count and size limits.
    static func plan(listen: [Episode], preferences: DownloadPreferences) -> [Episode] {
        guard preferences.automatic else { return [] }
        var total = 0
        var plan: [Episode] = []
        for episode in listen.prefix(preferences.count) {
            guard let manifest = episode.manifest else { continue }
            if total + manifest.bytes > preferences.limit { break }
            total += manifest.bytes
            plan.append(episode)
        }
        return plan
    }

    /// Download one episode now, ahead of the automatic queue.
    func request(_ episode: Episode) {
        errors[episode.id] = nil
        requested.removeAll { $0 == episode.id }
        requested.insert(episode.id, at: 0)
        run()
    }

    /// Re-plan: remove files nothing needs, then fetch what is missing.
    func run() {
        again = true
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            let background = UIApplication.shared.beginBackgroundTask(withName: "pods-downloads")
            while self.again {
                self.again = false
                await self.pass()
            }
            self.worker = nil
            UIApplication.shared.endBackgroundTask(background)
        }
    }

    private func pass() async {
        let library = Library.shared
        sweep(library)
        while let episode = nextWanted(library) {
            guard let manifest = episode.manifest else { continue }
            do {
                try await download(episode, manifest)
                errors[episode.id] = nil
                notice = nil
            } catch is CancellationError {
                return
            } catch SyncError.unreachable {
                notice = "Mac unavailable. Downloads resume when it is reachable."
                progress[episode.id] = nil
                return
            } catch SyncError.unauthorized {
                notice = "Pair this iPhone with the Mac to download."
                progress[episode.id] = nil
                return
            } catch {
                // Skip this episode; the rest of the queue continues.
                errors[episode.id] = error.localizedDescription
                progress[episode.id] = nil
                requested.removeAll { $0 == episode.id }
            }
        }
    }

    private func nextWanted(_ library: Library) -> Episode? {
        while let id = requested.first {
            if let episode = library.episode(id), episode.manifest != nil, !isDownloaded(episode) { return episode }
            requested.removeFirst()
        }
        return Self.plan(listen: library.listen, preferences: library.device.preferences)
            .first { !isDownloaded($0) && errors[$0.id] == nil }
    }

    /// Delete files that no unplayed episode uses any more. The playing file is never removed.
    private func sweep(_ library: Library) {
        guard library.snapshot != nil else { return }
        let wanted = Set(library.listen.compactMap { $0.manifest?.hash })
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let hash = file.deletingPathExtension().lastPathComponent
            if !wanted.contains(hash) && hash != protectedHash { try? FileManager.default.removeItem(at: file) }
        }
        scan()
    }

    // MARK: Transfer

    private func download(_ episode: Episode, _ manifest: Manifest) async throws {
        let part = Self.partURL(manifest)
        let size = manifest.chunk_size
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        let existing = (try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        // Only whole verified chunks are ever kept; drop a torn tail.
        var index = min(existing / size, manifest.chunks.count)
        try handle.truncate(atOffset: UInt64(min(index * size, manifest.bytes)))
        try handle.seekToEnd()
        progress[episode.id] = Progress(received: min(index * size, manifest.bytes), total: manifest.bytes)

        let perRequest = 4
        while index < manifest.chunks.count {
            try Task.checkCancellation()
            let last = min(index + perRequest, manifest.chunks.count) - 1
            let start = index * size
            let end = min((last + 1) * size, manifest.bytes) - 1
            let data = try await fetch(hash: manifest.hash, start: start, end: end, total: manifest.bytes)
            let hashes = Array(manifest.chunks[index...last])
            let verified = await Task.detached(priority: .utility) { Self.verify(data, chunkSize: size, hashes: hashes) }.value
            guard verified else { throw SyncError.message("Audio verification failed. It will be retried.") }
            try handle.write(contentsOf: data)
            index = last + 1
            progress[episode.id] = Progress(received: end + 1, total: manifest.bytes)
        }
        try handle.synchronize()
        let final = Self.fileURL(manifest)
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: part, to: final)
        progress[episode.id] = nil
        scan()
    }

    /// One range, retried twice on a dropped connection before the queue gives up on the Mac.
    private func fetch(hash: String, start: Int, end: Int, total: Int) async throws -> Data {
        var delays: [UInt64] = [1, 3]
        while true {
            do { return try await client.artifactRange(hash: hash, start: start, end: end, total: total) }
            catch SyncError.unreachable {
                guard !delays.isEmpty else { throw SyncError.unreachable }
                try await Task.sleep(nanoseconds: delays.removeFirst() * 1_000_000_000)
            }
        }
    }

    nonisolated static func verify(_ data: Data, chunkSize: Int, hashes: [String]) -> Bool {
        var offset = data.startIndex
        for expected in hashes {
            let end = min(offset + chunkSize, data.endIndex)
            guard offset < end else { return false }
            let digest = SHA256.hash(data: data[offset..<end]).map { String(format: "%02x", $0) }.joined()
            if digest != expected { return false }
            offset = end
        }
        return offset == data.endIndex
    }

    func removeAll() {
        worker?.cancel()
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.deletingPathExtension().lastPathComponent != protectedHash { try? FileManager.default.removeItem(at: file) }
        progress = [:]; errors = [:]
        scan()
    }
}
