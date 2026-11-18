import CryptoKit
import Foundation
import Observation
import UIKit

/// Keeps processed episode files on the phone. Transfers run in a background
/// URLSession, so they continue while the app is suspended or closed. Every
/// 1 MiB chunk is checked against the Mac's manifest before it is written, and a
/// file becomes playable only once every chunk is in place.
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
    /// Transfer state of each episode being fetched, and bytes of segments in flight.
    @ObservationIgnored private var parts: [String: MediaStore.Part] = [:]
    @ObservationIgnored private var inflight: [String: [Int: Int]] = [:]
    @ObservationIgnored private var episodeIDs: [String: Int] = [:]
    @ObservationIgnored private var failures: [String: Int] = [:]
    /// The artifact an error belongs to; a new publication of the episode clears it.
    @ObservationIgnored private var errorHashes: [Int: String] = [:]
    @ObservationIgnored private let store = MediaStore.shared

    /// Segments queued with iOS at once: enough to keep going for a while in the
    /// background, few enough that the listening order decides what arrives first.
    static let maxQueued = 24
    /// Verification failures before an episode stops retrying until it is requested again.
    static let maxFailures = 3

    init() { scan() }

    static func fileURL(_ manifest: Manifest) -> URL { MediaStore.shared.finalURL(manifest.hash, manifest.fileExtension) }

    func isDownloaded(_ episode: Episode) -> Bool { episode.manifest.map { complete.contains($0.hash) } ?? false }
    func fileURL(for episode: Episode) -> URL? {
        guard let manifest = episode.manifest, complete.contains(manifest.hash) else { return nil }
        return Self.fileURL(manifest)
    }

    private func scan() {
        let inventory = store.inventory()
        complete = inventory.complete
        usedBytes = inventory.bytes
    }

    // MARK: Queue

    /// Episodes the automatic queue wants, in Listen order, within the count and size limits.
    nonisolated static func plan(listen: [Episode], preferences: DownloadPreferences) -> [Episode] {
        guard preferences.automatic else { return [] }
        var total = 0
        var plan: [Episode] = []
        for episode in listen.prefix(preferences.count) {
            // A summary has no chunk hashes to verify against; the next pull completes it.
            guard let manifest = episode.manifest, !episode.isSummary else { continue }
            if total + manifest.bytes > preferences.limit { break }
            total += manifest.bytes
            plan.append(episode)
        }
        return plan
    }

    /// Download one episode now, ahead of the automatic queue.
    func request(_ episode: Episode) {
        errors[episode.id] = nil
        errorHashes[episode.id] = nil
        if let hash = episode.manifest?.hash { failures[hash] = nil }
        requested.removeAll { $0 == episode.id }
        requested.insert(episode.id, at: 0)
        if episode.isSummary {
            Task {
                await Library.shared.loadFull(episode.id)
                self.run()
            }
        } else {
            run()
        }
    }

    /// Re-plan: remove files nothing needs, stop transfers nothing wants, queue what is missing.
    func run() {
        again = true
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await BackgroundWork.run("pods-downloads") {
                while self.again {
                    self.again = false
                    await self.pass()
                }
            }
            self.worker = nil
        }
    }

    /// Re-plan and wait, for background wake-ups that must queue work before iOS suspends the app.
    func runNow() async {
        run()
        await worker?.value
    }

    private func wanted(_ library: Library) -> [Episode] {
        requested.removeAll { id in library.episode(id).map { isDownloaded($0) || $0.manifest == nil } ?? true }
        var result: [Episode] = []
        var seen = Set<Int>()
        for id in requested {
            // A summary waits in `requested` until `Library.loadFull` replaces it.
            if let episode = library.episode(id), !episode.isSummary, seen.insert(id).inserted { result.append(episode) }
        }
        for episode in Self.plan(listen: library.listen, preferences: library.device.preferences)
        where !seen.contains(episode.id) && !isDownloaded(episode) {
            if errors[episode.id] != nil, errorHashes[episode.id] != episode.manifest?.hash {
                errors[episode.id] = nil
                errorHashes[episode.id] = nil
            }
            if errors[episode.id] == nil, seen.insert(episode.id).inserted { result.append(episode) }
        }
        return result
    }

    private func pass() async {
        let library = Library.shared
        guard library.snapshot != nil else { return }
        let transfers = Transfers.shared
        let running = await transfers.tasks()
        let wanted = wanted(library)
        let wantedHashes = Set(wanted.compactMap { $0.manifest?.hash })

        // Stop transfers nothing wants now. Their partial files stay while the episode is unplayed.
        var queued = Set<Transfers.Info>()
        for (info, task) in running {
            if wantedHashes.contains(info.hash), task.state != .canceling { queued.insert(info) } else { task.cancel() }
        }
        var keep = Set(library.listen.compactMap { $0.manifest?.hash }).union(wantedHashes)
        if let protectedHash { keep.insert(protectedHash) }
        store.sweep(keep: keep)
        scan()

        var budget = Self.maxQueued - queued.count
        var shown: [String: Int] = [:]
        for (rank, episode) in wanted.enumerated() {
            guard let manifest = episode.manifest, !complete.contains(manifest.hash) else { continue }
            let hasQueued = queued.contains { $0.hash == manifest.hash }
            // Start state for an episode only when it can be queued now or already has some.
            guard budget > 0 || hasQueued || store.part(manifest.hash) != nil else { continue }
            let part = store.prepare(manifest)
            parts[manifest.hash] = part
            shown[manifest.hash] = episode.id
            for segment in 0..<part.segments where !part.done[segment] && budget > 0 {
                let info = Transfers.Info(hash: manifest.hash, segment: segment)
                if queued.contains(info) { continue }
                transfers.start(info, range: part.byteRange(segment),
                                priority: rank == 0 ? URLSessionTask.highPriority : URLSessionTask.defaultPriority)
                queued.insert(info)
                budget -= 1
            }
        }
        episodeIDs = shown
        parts = parts.filter { shown[$0.key] != nil }
        inflight = inflight.filter { shown[$0.key] != nil }
        let ids = Set(shown.values)
        progress = progress.filter { ids.contains($0.key) }
        for hash in shown.keys { updateProgress(hash) }
    }

    // MARK: Transfer events (from `Transfers`)

    func received(_ info: Transfers.Info, bytes: Int) {
        guard episodeIDs[info.hash] != nil else { return }
        inflight[info.hash, default: [:]][info.segment] = bytes
        updateProgress(info.hash)
    }

    func finished(_ info: Transfers.Info, _ outcome: Transfers.Outcome) {
        inflight[info.hash]?[info.segment] = nil
        switch outcome {
        case .stored(let whole):
            notice = nil
            if whole {
                failures[info.hash] = nil
                parts[info.hash] = nil
                inflight[info.hash] = nil
                if let id = episodeIDs[info.hash] { progress[id] = nil }
                scan()
                DeviceLog.write("downloaded \(info.hash.prefix(12))")
            } else {
                if let part = store.part(info.hash) { parts[info.hash] = part }
                updateProgress(info.hash)
            }
            run()
        case .stale, .cancelled:
            updateProgress(info.hash)
        case .unreachable:
            // Retried on the next foreground, timer tick or background refresh.
            notice = "Mac unavailable. Downloads resume when it is reachable."
        case .unauthorized:
            notice = "Pair this iPhone with the Mac to download."
        case .failed(let message):
            let count = (failures[info.hash] ?? 0) + 1
            failures[info.hash] = count
            DeviceLog.write("download failed \(info.hash.prefix(12)) segment=\(info.segment) count=\(count): \(message)")
            if count >= Self.maxFailures, let id = episodeIDs[info.hash] {
                errors[id] = message
                errorHashes[id] = info.hash
                progress[id] = nil
                requested.removeAll { $0 == id }
            }
            run()
        }
    }

    private func updateProgress(_ hash: String) {
        guard let id = episodeIDs[hash], let part = parts[hash] else { return }
        let received = part.receivedBytes + (inflight[hash]?.values.reduce(0, +) ?? 0)
        progress[id] = Progress(received: min(received, part.bytes), total: part.bytes)
    }

    func removeAll() {
        Task { for (_, task) in await Transfers.shared.tasks() { task.cancel() } }
        store.removeAll(except: protectedHash)
        requested = []; progress = [:]; errors = [:]; errorHashes = [:]
        parts = [:]; inflight = [:]; failures = [:]; episodeIDs = [:]
        scan()
    }
}

/// The Media folder. `<hash>.<m4a|mp4>` is a complete, verified episode;
/// `<hash>.part` holds verified segments at their offsets and `<hash>.json`
/// records which. The main actor and the transfer delegate both change it, so
/// every change happens under one lock.
final class MediaStore: @unchecked Sendable {
    static let shared = MediaStore()
    /// Chunks per transfer. The Mac reads each range into memory, so ranges stay small.
    static let segmentChunks = 8

    struct Part: Codable, Equatable {
        var hash: String
        var ext: String
        var bytes: Int
        var chunk_size: Int
        var chunks: [String]
        var done: [Bool]

        init(_ manifest: Manifest) {
            hash = manifest.hash
            ext = manifest.fileExtension
            bytes = manifest.bytes
            chunk_size = manifest.chunk_size
            chunks = manifest.chunks
            done = Array(repeating: false, count: (manifest.chunks.count + MediaStore.segmentChunks - 1) / MediaStore.segmentChunks)
        }

        var segments: Int { done.count }
        var isComplete: Bool { !done.isEmpty && !done.contains(false) }
        func chunkRange(_ segment: Int) -> Range<Int> {
            segment * MediaStore.segmentChunks ..< min((segment + 1) * MediaStore.segmentChunks, chunks.count)
        }
        /// Inclusive, as an HTTP Range header wants it.
        func byteRange(_ segment: Int) -> ClosedRange<Int> {
            let range = chunkRange(segment)
            return range.lowerBound * chunk_size ... min(range.upperBound * chunk_size, bytes) - 1
        }
        var receivedBytes: Int { done.indices.reduce(0) { $0 + (done[$1] ? byteRange($1).count : 0) } }
        func matches(_ manifest: Manifest) -> Bool {
            hash == manifest.hash && ext == manifest.fileExtension && bytes == manifest.bytes
                && chunk_size == manifest.chunk_size && chunks == manifest.chunks
        }
        /// Usable only if its numbers describe a real file.
        var isConsistent: Bool {
            bytes > 0 && chunk_size > 0 && chunks.count == (bytes + chunk_size - 1) / chunk_size
                && done.count == (chunks.count + MediaStore.segmentChunks - 1) / MediaStore.segmentChunks
        }
    }

    enum Stored: Equatable { case segment, complete, stale }
    enum Failure: LocalizedError {
        case size, verification
        var errorDescription: String? {
            switch self {
            case .size: return "The Mac sent the wrong amount of audio. It will be retried."
            case .verification: return "Audio verification failed. It will be retried."
            }
        }
    }

    let directory: URL
    private let lock = NSLock()

    init(directory: URL = DeviceLog.directory.appendingPathComponent("Media", isDirectory: true)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Episodes can always be fetched again from the Mac; keep them out of backups.
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }

    func finalURL(_ hash: String, _ ext: String) -> URL { directory.appendingPathComponent("\(hash).\(ext)") }
    func partURL(_ hash: String) -> URL { directory.appendingPathComponent("\(hash).part") }
    func stateURL(_ hash: String) -> URL { directory.appendingPathComponent("\(hash).json") }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    }

    private func readPart(_ hash: String) -> Part? {
        guard let data = try? Data(contentsOf: stateURL(hash)), let part = try? JSONDecoder().decode(Part.self, from: data),
              part.hash == hash, part.isConsistent else { return nil }
        return part
    }

    private func writePart(_ part: Part) throws {
        try JSONEncoder().encode(part).write(to: stateURL(part.hash), options: .atomic)
    }

    private func removeFiles(_ hash: String) {
        for file in files() where file.deletingPathExtension().lastPathComponent == hash {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Hashes of complete files, and the space every file in the folder uses.
    func inventory() -> (complete: Set<String>, bytes: Int) {
        lock.withLock {
            var complete = Set<String>(), bytes = 0
            for file in files() {
                bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if ["m4a", "mp4"].contains(file.pathExtension) { complete.insert(file.deletingPathExtension().lastPathComponent) }
            }
            return (complete, bytes)
        }
    }

    func part(_ hash: String) -> Part? { lock.withLock { readPart(hash) } }

    /// The transfer state for this manifest, started fresh when there is none or it no longer matches.
    func prepare(_ manifest: Manifest) -> Part {
        lock.withLock {
            if let part = readPart(manifest.hash), part.matches(manifest) { return part }
            try? FileManager.default.removeItem(at: partURL(manifest.hash))
            let part = Part(manifest)
            try? writePart(part)
            return part
        }
    }

    /// Check one finished transfer against the manifest and write it into place. Runs on
    /// the transfer delegate's queue; `location` is deleted once the delegate returns.
    func store(hash: String, segment: Int, from location: URL) throws -> Stored {
        guard let expected = part(hash), expected.done.indices.contains(segment) else { return .stale }
        let range = expected.byteRange(segment)
        let data = try Data(contentsOf: location, options: .mappedIfSafe)
        guard data.count == range.count else { throw Failure.size }
        guard Self.verify(data, chunkSize: expected.chunk_size, hashes: Array(expected.chunks[expected.chunkRange(segment)]))
        else { throw Failure.verification }
        return try lock.withLock {
            // The episode may have been removed, or started over, while this transfer ran.
            guard var part = readPart(hash), part.chunks == expected.chunks, part.done.indices.contains(segment) else { return .stale }
            if part.done[segment] { return .segment }
            let url = partURL(hash)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.seek(toOffset: UInt64(range.lowerBound))
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            part.done[segment] = true
            guard part.isComplete else {
                try writePart(part)
                return .segment
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            guard size == part.bytes else {
                // Should not happen: every segment landed at its offset. Start the episode over.
                removeFiles(hash)
                throw Failure.size
            }
            let final = finalURL(hash, part.ext)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: url, to: final)
            try? FileManager.default.removeItem(at: stateURL(hash))
            return .complete
        }
    }

    /// Delete files for every hash not in `keep`, plus leftovers that cannot be trusted:
    /// a `.part` with no state (the old in-app downloader) and state for a finished file.
    func sweep(keep: Set<String>) {
        lock.withLock {
            let names = Set(files().map(\.lastPathComponent))
            for file in files() {
                let hash = file.deletingPathExtension().lastPathComponent
                let orphan: Bool
                switch file.pathExtension {
                case "part": orphan = !names.contains("\(hash).json")
                case "json": orphan = names.contains("\(hash).m4a") || names.contains("\(hash).mp4")
                case "m4a", "mp4": orphan = false
                default: orphan = true
                }
                if !keep.contains(hash) || orphan { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    func removeAll(except hash: String?) {
        lock.withLock {
            for file in files() where file.deletingPathExtension().lastPathComponent != hash {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func verify(_ data: Data, chunkSize: Int, hashes: [String]) -> Bool {
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
}

/// The background URLSession that moves episode files. It keeps running while the app
/// is suspended; iOS relaunches the app in the background to hand over finished work.
final class Transfers: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = Transfers()
    static let identifier = "dev.mcgiv.pods.media"

    struct Info: Codable, Hashable { var hash: String; var segment: Int }
    enum Outcome: Equatable { case stored(complete: Bool), stale, cancelled, unreachable, unauthorized, failed(String) }

    private let lock = NSLock()
    private var outcomes: [Int: Outcome] = [:]
    private var lastProgress: [Int: Date] = [:]
    private var eventsDone: (() -> Void)?
    private let store = MediaStore.shared
    private(set) var session: URLSession!

    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        // The Mac reads each range into memory; two at a time keeps that small.
        configuration.httpMaximumConnectionsPerHost = 2
        // Cookies are attached by hand below, from the store the foreground client fills.
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        let queue = OperationQueue()
        queue.name = "dev.mcgiv.pods.transfers"
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// Keep the handler iOS passes when it relaunches the app for this session's events.
    func handleEvents(_ completion: @escaping () -> Void) {
        lock.withLock { eventsDone = completion }
    }

    func start(_ info: Info, range: ClosedRange<Int>, priority: Float) {
        guard let url = URL(string: "/api/artifacts/\(info.hash)", relativeTo: MacClient.base)?.absoluteURL,
              let description = try? String(data: JSONEncoder().encode(info), encoding: .utf8) else { return }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        request.setValue("\"\(info.hash)\"", forHTTPHeaderField: "If-Range")
        MacClient.identify(&request)
        for (name, value) in HTTPCookie.requestHeaderFields(with: HTTPCookieStorage.shared.cookies(for: url) ?? []) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let task = session.downloadTask(with: request)
        task.taskDescription = description
        task.priority = priority
        task.countOfBytesClientExpectsToSend = 1024
        task.countOfBytesClientExpectsToReceive = Int64(range.count)
        task.resume()
    }

    func tasks() async -> [(info: Info, task: URLSessionTask)] {
        await session.allTasks.compactMap { task in Self.info(task).map { ($0, task) } }
    }

    static func info(_ task: URLSessionTask) -> Info? {
        task.taskDescription.flatMap { try? JSONDecoder().decode(Info.self, from: Data($0.utf8)) }
    }

    /// What a finished transfer's response means, before any data is written.
    static func classify(status: Int, contentRange: String?, expected: ClosedRange<Int>?, total: Int?) -> Outcome? {
        switch status {
        case 401, 403: return .unauthorized
        case 500...: return .unreachable
        case 206:
            guard let expected, let total, contentRange == "bytes \(expected.lowerBound)-\(expected.upperBound)/\(total)" else {
                return expected == nil ? .stale : .failed("Audio changed on the Mac. It will download again after the next sync.")
            }
            return nil
        default:
            return .failed("Audio changed on the Mac. It will download again after the next sync.")
        }
    }

    // MARK: URLSessionDownloadDelegate (on the serial delegate queue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let info = Self.info(downloadTask) else { return }
        let http = downloadTask.response as? HTTPURLResponse
        let part = store.part(info.hash)
        let expected = part.flatMap { $0.done.indices.contains(info.segment) ? $0.byteRange(info.segment) : nil }
        var outcome = Self.classify(status: http?.statusCode ?? 0, contentRange: http?.value(forHTTPHeaderField: "content-range"),
                                    expected: expected, total: part?.bytes)
        if outcome == nil {
            do {
                switch try store.store(hash: info.hash, segment: info.segment, from: location) {
                case .segment: outcome = .stored(complete: false)
                case .complete: outcome = .stored(complete: true)
                case .stale: outcome = .stale
                }
            } catch {
                outcome = .failed(error.localizedDescription)
            }
        }
        lock.withLock { outcomes[downloadTask.taskIdentifier] = outcome }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let recorded = lock.withLock { () -> Outcome? in
            lastProgress[task.taskIdentifier] = nil
            return outcomes.removeValue(forKey: task.taskIdentifier)
        }
        guard let info = Self.info(task) else { return }
        let outcome: Outcome
        if let error {
            outcome = (error as? URLError)?.code == .cancelled ? .cancelled : .unreachable
        } else {
            outcome = recorded ?? .unreachable
        }
        Task { @MainActor in Downloads.shared.finished(info, outcome) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let info = Self.info(downloadTask) else { return }
        let now = Date(), id = downloadTask.taskIdentifier
        let due = lock.withLock { () -> Bool in
            if let last = lastProgress[id], now.timeIntervalSince(last) < 0.5 { return false }
            lastProgress[id] = now
            return true
        }
        guard due else { return }
        Task { @MainActor in Downloads.shared.received(info, bytes: Int(totalBytesWritten)) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock { () -> (() -> Void)? in
            defer { eventsDone = nil }
            return eventsDone
        }
        Task { @MainActor in
            // Queue the next segments before iOS suspends the app again.
            await Downloads.shared.runNow()
            completion?()
        }
    }
}

/// Run work that should finish even if the app leaves the screen, within the time iOS allows.
enum BackgroundWork {
    @MainActor static func run(_ name: String, _ work: @MainActor () async -> Void) async {
        final class Token { var id = UIBackgroundTaskIdentifier.invalid }
        let token = Token()
        token.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(token.id)
            token.id = .invalid
        }
        await work()
        if token.id != .invalid { UIApplication.shared.endBackgroundTask(token.id) }
    }

    /// Wait for `work`, but no longer than `seconds`. The work itself carries on.
    static func waitAtMost(_ seconds: Double, _ work: @escaping @MainActor () async -> Void) async {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Void, Never>?
            init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
            func resume() {
                let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { continuation = nil }; return continuation }
                pending?.resume()
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once(continuation)
            Task { @MainActor in await work(); once.resume() }
            Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); once.resume() }
        }
    }
}
