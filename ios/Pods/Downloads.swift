import CryptoKit
import Foundation
import Observation
import UIKit

/// Keeps processed episode files on the phone. Transfers run in a background
/// URLSession, so they continue while iOS suspends or ends the app (not after a
/// force-quit from the app switcher, which cancels them). Every
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
    /// An episode asked for by hand, with its finished state at the time. It stays wanted,
    /// and its file stays, until that state changes (it is played or archived).
    struct Request: Codable, Equatable { var id: Int; var played_at: Double?; var archived_at: Double? }
    /// Newest first. Saved, because their transfers outlive the app and the first pass
    /// after a relaunch would otherwise cancel them as unwanted.
    @ObservationIgnored private(set) var requested: [Request] = [] {
        didSet { if requested != oldValue { Self.save(requested, to: defaults) } }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastLibraryKey = ""
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

    nonisolated static let requestedKey = "PodsRequestedDownloads"

    /// Segments queued with iOS at once. iOS runs transfers queued while the app is in
    /// the background only when it chooses (Wi-Fi, power), so the whole plan is queued
    /// while the app is on screen: one segment per 8 MiB of the storage limit, plus one per
    /// episode for its last, partial segment (306 at the defaults), up to 512. Priority, not
    /// the queue length, keeps the listening order.
    nonisolated static func queueLimit(_ preferences: DownloadPreferences) -> Int {
        let segment = MediaStore.segmentChunks * 1024 * 1024
        return min(maxQueue, max(32, preferences.limit / segment + preferences.count))
    }
    /// Kept modest: every queued task is tracked by the system's transfer daemon.
    nonisolated static let maxQueue = 512
    /// Verification failures before an episode stops retrying until it is requested again.
    nonisolated static let maxFailures = 3

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        requested = Self.loadRequests(from: defaults)
        scan()
    }

    nonisolated static func loadRequests(from defaults: UserDefaults) -> [Request] {
        defaults.data(forKey: requestedKey).flatMap { try? JSONDecoder().decode([Request].self, from: $0) } ?? []
    }

    nonisolated static func save(_ requests: [Request], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(requests) { defaults.set(data, forKey: requestedKey) }
    }

    /// Requests still in force: the episode is still there with a file to fetch, and its
    /// finished state is what it was when it was asked for.
    nonisolated static func live(_ requests: [Request], episode: (Int) -> Episode?) -> [Request] {
        requests.filter { request in
            guard let current = episode(request.id), current.manifest != nil else { return false }
            return current.played_at == request.played_at && current.archived_at == request.archived_at
        }
    }

    /// Re-plan after a library change, but only when something downloads depend on moved:
    /// not for the position saves that bump the revision every few seconds during playback.
    func libraryChanged() {
        let library = Library.shared
        let key = Self.planKey(listen: library.listen, requested: requested.map { library.episode($0.id) },
                               preferences: library.device.preferences)
        guard key != lastLibraryKey else { return }
        lastLibraryKey = key
        run()
    }

    /// Everything the download plan depends on, and nothing else (positions change constantly).
    nonisolated static func planKey(listen: [Episode], requested: [Episode?], preferences: DownloadPreferences) -> String {
        var key = listen.map { "\($0.id):\($0.manifest?.hash ?? "-"):\($0.isSummary)" }
        key += requested.map { episode in
            episode.map { "r\($0.id):\($0.manifest?.hash ?? "-"):\($0.played_at ?? -1):\($0.archived_at ?? -1):\($0.isSummary)" } ?? "r-"
        }
        key.append("\(preferences.automatic):\(preferences.count):\(preferences.limit)")
        return key.joined(separator: ",")
    }

    /// Files the sweep must leave: Listen, everything wanted, every live request (a summary
    /// among them waits for its detail), and the one in the player.
    nonisolated static func keep(listen: [Episode], wanted: [Episode], requested: [Episode], protected: String?) -> Set<String> {
        var keep = Set((listen + wanted + requested).compactMap { $0.manifest?.hash })
        if let protected { keep.insert(protected) }
        return keep
    }

    /// Room for the whole plan plus the manual requests' missing segments, less what is queued.
    nonisolated static func budget(preferences: DownloadPreferences, manual: [Manifest], queued: Int) -> Int {
        let extra = manual.map { MediaStore.Part($0).segments }.reduce(0, +)
        return max(0, min(maxQueue, queueLimit(preferences) + extra) - queued)
    }

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
        requested.removeAll { $0.id == episode.id }
        requested.insert(Request(id: episode.id, played_at: episode.played_at, archived_at: episode.archived_at), at: 0)
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

    /// Requested episodes first (downloaded ones too, so the sweep keeps them), then the plan.
    private func wanted(_ library: Library) -> [Episode] {
        requested = Self.live(requested, episode: library.episode)
        var result: [Episode] = []
        var seen = Set<Int>()
        for request in requested {
            // A summary waits in `requested` until `Library.loadFull` fills it in.
            if let episode = library.episode(request.id), !episode.isSummary, seen.insert(request.id).inserted { result.append(episode) }
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

        let requestedEpisodes = requested.compactMap { library.episode($0.id) }
        store.sweep(keep: Self.keep(listen: library.listen, wanted: wanted, requested: requestedEpisodes, protected: protectedHash))
        scan()

        // Stop transfers nothing wants now, or for a file that is already complete. Partial
        // files stay while the episode is unplayed.
        var queued = Set<Transfers.Info>()
        for (info, task) in running {
            if wantedHashes.contains(info.hash), !complete.contains(info.hash), task.state != .canceling {
                queued.insert(info)
            } else {
                task.cancel()
            }
        }

        let budget = Self.budget(preferences: library.device.preferences,
                                 manual: requestedEpisodes.compactMap(\.manifest).filter { !complete.contains($0.hash) },
                                 queued: queued.count)
        let store = self.store
        let plan = Self.planPass(wanted: wanted.compactMap { episode in episode.manifest.map { (episode.id, $0) } },
                                 complete: complete, queued: queued, budget: budget,
                                 existing: { store.part($0) }, prepare: { store.prepare($0) })
        if !plan.finished.isEmpty {
            scan()
            for (info, task) in running where plan.finished.contains(info.hash) { task.cancel() }
        }
        queued = plan.queued
        var shown: [String: Int] = [:]
        for (id, part) in plan.active {
            parts[part.hash] = part
            shown[part.hash] = id
        }
        let schedule = Self.schedule(plan.active.map(\.part), queued: queued, budget: budget)
        // The order changes (a tap on Play, an episode finishing), so queued transfers follow it too.
        let changes = Self.priorityChanges(running.filter { queued.contains($0.info) }.map { ($0.info, $0.task.priority) }, schedule)
        for (info, task) in running { if let priority = changes[info] { task.priority = priority } }
        for planned in schedule.start {
            transfers.start(planned.info, range: planned.range, priority: planned.priority)
        }
        episodeIDs = shown
        parts = parts.filter { shown[$0.key] != nil }
        inflight = inflight.filter { shown[$0.key] != nil }
        let ids = Set(shown.values)
        progress = progress.filter { ids.contains($0.key) }
        for hash in shown.keys { updateProgress(hash) }
    }

    struct Planned: Equatable { var info: Transfers.Info; var range: ClosedRange<Int>; var priority: Float }
    struct Schedule: Equatable {
        /// Segments to queue now.
        var start: [Planned]
        /// The priority every transfer of each episode should have, queued or new.
        var priority: [String: Float]
    }

    /// Each episode's missing segments in order, episodes in the wanted order, within
    /// `budget`. The next episode is high priority, the one after default and the rest
    /// low, so iOS fetches the one about to be played first.
    nonisolated static func schedule(_ parts: [MediaStore.Part], queued: Set<Transfers.Info>, budget: Int) -> Schedule {
        var result = Schedule(start: [], priority: [:])
        for (rank, part) in parts.enumerated() {
            let priority = rank == 0 ? URLSessionTask.highPriority : rank == 1 ? URLSessionTask.defaultPriority : URLSessionTask.lowPriority
            result.priority[part.hash] = priority
            for segment in part.done.indices where !part.done[segment] {
                let info = Transfers.Info(hash: part.hash, segment: segment)
                if queued.contains(info) || result.start.count >= budget { continue }
                result.start.append(Planned(info: info, range: part.byteRange(segment), priority: priority))
            }
        }
        return result
    }

    struct PassPlan {
        /// Episodes with transfer state to follow, in wanted order.
        var active: [(id: Int, part: MediaStore.Part)]
        /// Files that turned out complete during the pass (a segment landed since the scan).
        var finished: Set<String>
        /// Queued transfers still wanted: those for finished files are dropped.
        var queued: Set<Transfers.Info>
    }

    /// Which wanted episodes get transfer state now: those already started, plus new ones
    /// while there is room. `existing` and `prepare` are the store's.
    nonisolated static func planPass(wanted: [(id: Int, manifest: Manifest)], complete: Set<String>, queued: Set<Transfers.Info>,
                                     budget: Int, existing: (String) -> MediaStore.Part?,
                                     prepare: (Manifest) -> MediaStore.Part?) -> PassPlan {
        var plan = PassPlan(active: [], finished: [], queued: queued)
        var remaining = budget
        for (id, manifest) in wanted where !complete.contains(manifest.hash) {
            let hasQueued = plan.queued.contains { $0.hash == manifest.hash }
            let current = existing(manifest.hash)
            guard remaining > 0 || hasQueued || current != nil else { continue }
            // Nil from `prepare`: the last segment landed since the scan, so the file is complete.
            guard let part = current.flatMap({ $0.matches(manifest) ? $0 : nil }) ?? prepare(manifest) else {
                plan.finished.insert(manifest.hash)
                plan.queued = plan.queued.filter { $0.hash != manifest.hash }
                continue
            }
            plan.active.append((id, part))
            remaining -= part.done.indices.filter { !part.done[$0] && !plan.queued.contains(.init(hash: part.hash, segment: $0)) }.count
        }
        return plan
    }

    /// Queued transfers whose priority differs from what the schedule now gives their episode.
    nonisolated static func priorityChanges(_ queued: [(info: Transfers.Info, priority: Float)], _ schedule: Schedule)
        -> [Transfers.Info: Float] {
        var changes: [Transfers.Info: Float] = [:]
        for (info, current) in queued {
            if let wanted = schedule.priority[info.hash], wanted != current { changes[info] = wanted }
        }
        return changes
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
                requested.removeAll { $0.id == id }
            }
            run()
        }
    }

    private func updateProgress(_ hash: String) {
        guard let id = episodeIDs[hash], let part = parts[hash] else { return }
        progress[id] = Self.progress(part, inflight: inflight[hash])
    }

    /// What an episode's row shows: nothing until some of it has arrived or is arriving, so
    /// the rest of the queued plan does not all read "Downloading".
    nonisolated static func progress(_ part: MediaStore.Part, inflight: [Int: Int]?) -> Progress? {
        let moving = inflight?.values.reduce(0, +) ?? 0
        guard part.receivedBytes > 0 || !(inflight ?? [:]).isEmpty else { return nil }
        return Progress(received: min(part.receivedBytes + moving, part.bytes), total: part.bytes)
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
        /// New each time an episode starts over, so a write that raced a restart is discarded.
        var generation: String

        init(_ manifest: Manifest) {
            hash = manifest.hash
            ext = manifest.fileExtension
            bytes = manifest.bytes
            chunk_size = manifest.chunk_size
            chunks = manifest.chunks
            done = Array(repeating: false, count: (manifest.chunks.count + MediaStore.segmentChunks - 1) / MediaStore.segmentChunks)
            generation = UUID().uuidString
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
    /// Tests only: runs between writing a segment and recording it.
    var afterWrite: (() -> Void)?

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

    private func fileSize(_ url: URL) -> Int? { try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize }

    private func hasFinal(_ hash: String) -> Bool {
        ["m4a", "mp4"].contains { FileManager.default.fileExists(atPath: finalURL(hash, $0).path) }
    }

    /// The transfer state, if it can be trusted: not left next to a finished file, and not
    /// claiming segments the partial file cannot hold (an interrupted removal or finish).
    private func readPart(_ hash: String) -> Part? {
        guard let data = try? Data(contentsOf: stateURL(hash)), let part = try? JSONDecoder().decode(Part.self, from: data),
              part.hash == hash, part.isConsistent, !hasFinal(hash) else { return nil }
        if let last = part.done.lastIndex(of: true) {
            guard let size = fileSize(partURL(hash)), size > part.byteRange(last).upperBound else { return nil }
        }
        return part
    }

    private func writePart(_ part: Part) throws {
        try JSONEncoder().encode(part).write(to: stateURL(part.hash), options: .atomic)
    }

    /// Forget a transfer. A finished file for the same hash stays.
    private func removeTransfer(_ hash: String) {
        try? FileManager.default.removeItem(at: partURL(hash))
        try? FileManager.default.removeItem(at: stateURL(hash))
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
    /// Nil when the file is already complete: no state is started next to a finished file.
    func prepare(_ manifest: Manifest) -> Part? {
        lock.withLock {
            if hasFinal(manifest.hash) { return nil }
            if let part = readPart(manifest.hash), part.matches(manifest) { return part }
            try? FileManager.default.removeItem(at: partURL(manifest.hash))
            let part = Part(manifest)
            try? writePart(part)
            return part
        }
    }

    /// Check one finished transfer against the manifest and write it into place. Runs on
    /// the transfer delegate's serial queue (the only writer of partial files);
    /// `location` is deleted once the delegate returns.
    func store(hash: String, segment: Int, from location: URL) throws -> Stored {
        guard let expected = part(hash), expected.done.indices.contains(segment) else { return .stale }
        if expected.done[segment] { return .segment }
        let range = expected.byteRange(segment)
        let data = try Data(contentsOf: location, options: .mappedIfSafe)
        guard data.count == range.count else { throw Failure.size }
        guard Self.verify(data, chunkSize: expected.chunk_size, hashes: Array(expected.chunks[expected.chunkRange(segment)]))
        else { throw Failure.verification }
        // Write and flush outside the lock, so the main thread never waits on the disk. If the
        // episode is removed or restarted meanwhile, the generation check below drops this write;
        // the bytes it left in a newer partial file sit in a segment still marked missing.
        let url = partURL(hash)
        if !FileManager.default.fileExists(atPath: url.path), !FileManager.default.createFile(atPath: url.path, contents: nil) {
            throw CocoaError(.fileWriteUnknown)
        }
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
        afterWrite?()
        return try lock.withLock {
            guard var part = readPart(hash), part.generation == expected.generation else { return .stale }
            if part.done[segment] { return .segment }
            part.done[segment] = true
            guard part.isComplete else {
                try writePart(part)
                return .segment
            }
            guard fileSize(url) == part.bytes else {
                // Should not happen: every segment landed at its offset. Start the episode over.
                removeTransfer(hash)
                throw Failure.size
            }
            try FileManager.default.moveItem(at: url, to: finalURL(hash, part.ext))
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
    /// When the session finished delivering events before iOS handed over its handler.
    private var eventsFinishedAt: Date?
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
    /// The session may already exist (launch and background refresh create it too) and may
    /// have finished delivering before this runs; then the handler is called right away.
    func handleEvents(_ completion: @escaping () -> Void) {
        let finished = lock.withLock { () -> Bool in
            defer { eventsFinishedAt = nil }
            if let at = eventsFinishedAt, Date().timeIntervalSince(at) < 60 { return true }
            eventsDone = completion
            return false
        }
        guard finished else { return }
        Task { @MainActor in
            await Downloads.shared.runNow()
            completion()
        }
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

    /// What one finished transfer leads to: check the response, then verify and store its data.
    static func process(_ info: Info, status: Int, contentRange: String?, location: URL, store: MediaStore) -> Outcome {
        let part = store.part(info.hash)
        let expected = part.flatMap { $0.done.indices.contains(info.segment) ? $0.byteRange(info.segment) : nil }
        if let outcome = classify(status: status, contentRange: contentRange, expected: expected, total: part?.bytes) {
            return outcome
        }
        do {
            switch try store.store(hash: info.hash, segment: info.segment, from: location) {
            case .segment: return .stored(complete: false)
            case .complete: return .stored(complete: true)
            case .stale: return .stale
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let info = Self.info(downloadTask) else { return }
        let http = downloadTask.response as? HTTPURLResponse
        let outcome = Self.process(info, status: http?.statusCode ?? 0, contentRange: http?.value(forHTTPHeaderField: "content-range"),
                                   location: location, store: store)
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
            if eventsDone == nil { eventsFinishedAt = Date() }
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
