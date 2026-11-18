import Foundation
import Observation
import UIKit

/// The phone's copy of the library plus the queue of local changes, kept in step
/// with the Mac. Mirrors the browser client's offline store and sync loop.
@MainActor @Observable
final class Library {
    static let shared = Library()

    enum Pairing: Equatable { case unknown, paired, unpaired }

    private(set) var snapshot: Snapshot?
    private(set) var device = DeviceState()
    /// Snapshot with unsent local changes applied. This is what every screen reads.
    private(set) var view: Snapshot?
    private(set) var pairing: Pairing = .unknown
    private(set) var syncing = false
    private(set) var lastError: String?
    /// Bumped whenever the set of episodes may have changed, so downloads re-plan.
    private(set) var revision = 0

    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var refreshRequested = false
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var playbackBases: [String: Int] = [:]
    @ObservationIgnored private let client = MacClient.shared
    /// UI tests run against the real Mac library and must never change it: local
    /// changes stay in memory and are never sent. Only a launch argument sets this.
    @ObservationIgnored let readOnly = UserDefaults.standard.bool(forKey: "PodsReadOnly")

    nonisolated private static let snapshotURL = DeviceLog.directory.appendingPathComponent("snapshot.json")
    nonisolated private static let deviceURL = DeviceLog.directory.appendingPathComponent("device.json")
    static let pairCodeURL = DeviceLog.directory.appendingPathComponent("pair-code")

    init() {
        if let data = try? Data(contentsOf: Self.deviceURL), let saved = try? JSONDecoder().decode(DeviceState.self, from: data) {
            device = saved
        }
        if let data = try? Data(contentsOf: Self.snapshotURL), let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = saved
        }
        if snapshot != nil { pairing = .paired }
        rebuild()
    }

    // MARK: Derived lists

    var episodes: [Episode] { view?.episodes ?? [] }
    var listen: [Episode] { episodes.filter(\.isUnplayed) }
    var played: [Episode] { episodes.filter { $0.played_at != nil }.sorted { ($0.played_at ?? 0) > ($1.played_at ?? 0) } }
    var shows: [Show] { view?.shows ?? [] }
    var speed: Double { view?.settings["speed"]?.doubleValue ?? 1 }
    var autoplay: Bool { view?.settings["autoplay"]?.boolValue ?? true }
    var lastListened: Int? { view?.settings["last_listened"]?.doubleValue.map { Int($0) } }
    var pendingChanges: Int { device.outbox.count }
    var rejectedChanges: [Operation] { device.outbox.filter { $0.error != nil } }
    func episode(_ id: Int) -> Episode? { episodes.first { $0.id == id } }

    private func rebuild() {
        view = snapshot.map { SyncLogic.applyOverlay($0, outbox: device.outbox) }
        revision += 1
    }

    // MARK: Persistence

    /// Writes run in order on one queue so an older state can never land last.
    private static let disk = DispatchQueue(label: "dev.mcgiv.pods.library-disk", qos: .utility)

    private func saveDevice() {
        guard !readOnly else { return }
        let state = device
        Self.disk.async {
            guard let data = try? JSONEncoder().encode(state) else { return }
            try? data.write(to: Self.deviceURL, options: .atomic)
        }
    }

    private func saveSnapshot() {
        guard let snapshot else { return }
        Self.disk.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.snapshotURL, options: .atomic)
        }
    }

    // MARK: Local changes

    func enqueue(_ entity: String, _ field: String, _ value: JSONValue, sync: Bool = true) {
        device.sequence += 1
        device.lastChangeAt = max(Int64(Date().timeIntervalSince1970 * 1000), device.lastChangeAt + 1)
        let key = "\(entity):\(field)"
        let base = (field == "position" ? playbackBases[entity] : nil) ?? snapshot?.versions[key] ?? 0
        device.outbox.append(Operation(id: UUID().uuidString.lowercased(), sequence: device.sequence, entity: entity, field: field,
                                       value: value, changed_at: device.lastChangeAt, base_revision: base))
        device.outbox = SyncLogic.coalesce(device.outbox)
        saveDevice()
        rebuild()
        if sync { synchronize(refresh: false) }
    }

    func setPlayed(_ episode: Episode, _ played: Bool) {
        enqueue(String(episode.id), "played", .bool(played), sync: !(!played && episode.position_secs > 0))
        // Unplayed restarts from the beginning. A finished episode's playhead sits at its end.
        if !played, episode.position_secs > 0, let manifest = episode.manifest {
            enqueue(String(episode.id), "position", .object(["seconds": .number(0), "artifact_hash": .string(manifest.hash), "original_seconds": .number(0)]))
        }
    }

    /// Record the playhead. `sync` is false for the frequent in-play saves; they ride the next sync.
    func setPosition(_ episode: Episode, seconds: Double, sync: Bool) {
        guard let manifest = episode.manifest, seconds.isFinite, seconds >= 0 else { return }
        var value: [String: JSONValue] = ["seconds": .number(seconds), "artifact_hash": .string(manifest.hash)]
        if let original = SyncLogic.originalTime(manifest.timeline, processed: seconds) { value["original_seconds"] = .number(original) }
        enqueue(String(episode.id), "position", .object(value), sync: sync)
    }

    func setSetting(_ field: String, _ value: JSONValue) {
        guard view?.settings[field] != value else { return }
        enqueue("settings", field, value)
    }

    func beginPlayback(_ episode: Episode) {
        playbackBases[String(episode.id)] = snapshot?.versions["\(episode.id):position"] ?? 0
        setSetting("last_listened", .number(Double(episode.id)))
    }

    func endPlayback(_ episode: Episode) { playbackBases[String(episode.id)] = nil }

    func subscribe(_ url: String) { enqueue("subscription", url, .bool(true)) }
    func unsubscribe(_ show: Show) { enqueue("subscription", show.feed_url, .bool(false)) }
    func addVideo(_ url: String) { enqueue("listen", url, .bool(true)) }
    func discard(_ operation: Operation) {
        device.outbox.removeAll { $0.id == operation.id }
        saveDevice(); rebuild()
    }

    func setPreferences(_ preferences: DownloadPreferences) {
        device.preferences = preferences
        saveDevice()
        revision += 1
    }

    // MARK: Pairing

    /// Use a code the Mac dropped into the app container at install time, if present.
    func adoptDeliveredPairCode() async {
        guard let raw = try? String(contentsOf: Self.pairCodeURL, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: Self.pairCodeURL)
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        do { try await pair(code: code); DeviceLog.write("paired from delivered code") }
        catch { DeviceLog.write("delivered pair code failed: \(error.localizedDescription)") }
    }

    func pair(code: String) async throws {
        try await client.pair(code: code.trimmingCharacters(in: .whitespacesAndNewlines))
        pairing = .paired
        lastError = nil
        synchronize(refresh: true)
    }

    // MARK: Sync

    func synchronize(refresh: Bool = true) {
        refreshRequested = refreshRequested || refresh
        syncAgain = true
        guard syncTask == nil else { return }
        syncing = true
        syncTask = Task { [weak self] in
            guard let self else { return }
            while self.syncAgain {
                self.syncAgain = false
                let pull = self.refreshRequested
                self.refreshRequested = false
                do {
                    try await self.synchronizeOnce(refresh: pull)
                    self.lastError = nil
                } catch is CancellationError {
                } catch {
                    if case SyncError.unauthorized = error { self.pairing = .unpaired }
                    self.lastError = error.localizedDescription
                    self.syncAgain = false
                }
            }
            self.syncTask = nil
            self.syncing = false
        }
    }

    /// Await the sync in flight (or a new one). Used by pull-to-refresh.
    func synchronizeAndWait() async {
        synchronize(refresh: true)
        await syncTask?.value
    }

    private func receiveSnapshot() async throws {
        let incoming = try await client.json(Snapshot.self, "/sync", headers: [
            "x-pods-client-id": device.client_id, "x-pods-device": Self.deviceName,
        ], timeout: 120)
        try SyncLogic.validate(incoming)
        snapshot = incoming
        pairing = .paired
        saveSnapshot()
        rebuild()
    }

    private func synchronizeOnce(refresh: Bool) async throws {
        var sharedWon = false
        if snapshot == nil { try await receiveSnapshot() }
        while !readOnly {
            device.outbox = SyncLogic.coalesce(device.outbox)
            let batch = SyncLogic.nextBatch(device.outbox)
            if batch.isEmpty { break }
            let ids = Set(batch.map(\.id))
            for index in device.outbox.indices where ids.contains(device.outbox[index].id) { device.outbox[index].sent = true }
            saveDevice()
            let results = try await post(batch)
            var missing = false
            for operation in batch {
                guard let result = results.first(where: { $0.id == operation.id }) else { missing = true; continue }
                switch result.status {
                case "applied":
                    let revision = result.revision ?? 0
                    if var current = snapshot, (current.versions[operation.key] ?? 0) <= revision {
                        current = SyncLogic.applyOverlay(current, outbox: [operation])
                        current.versions[operation.key] = revision
                        snapshot = current
                    }
                    device.outbox.removeAll { $0.id == operation.id }
                    for index in device.outbox.indices where device.outbox[index].key == operation.key
                        && device.outbox[index].sent != true && device.outbox[index].base_revision == operation.base_revision {
                        device.outbox[index].base_revision = revision
                    }
                    if operation.field == "position", playbackBases[operation.entity] == operation.base_revision {
                        playbackBases[operation.entity] = revision
                    }
                case "superseded", "conflict":
                    // A newer change from another device wins; pull it below.
                    device.outbox.removeAll { $0.id == operation.id }
                    playbackBases[operation.entity] = nil
                    sharedWon = true
                default:
                    if let index = device.outbox.firstIndex(where: { $0.id == operation.id }) {
                        device.outbox[index].error = result.error ?? "Change not acknowledged by the Mac."
                    }
                }
            }
            saveDevice()
            rebuild()
            if missing { throw SyncError.message("Mac did not acknowledge every change. Pending changes are saved and will retry.") }
        }
        // Push first so the pull below already reflects this device's changes.
        if refresh || sharedWon { try await receiveSnapshot() }
        device.lastSync = Date().timeIntervalSince1970
        saveDevice()
        saveSnapshot()
        rebuild()
    }

    private struct ActionsBody: Encodable {
        struct Action: Encodable {
            var id: String; var sequence: Int; var entity: String; var field: String
            var value: JSONValue; var base_revision: Int; var changed_at: Int64
        }
        var client_id: String; var device_name: String; var actions: [Action]
    }
    private struct ActionsResponse: Decodable { var results: [ActionResult] }

    private func post(_ batch: [Operation]) async throws -> [ActionResult] {
        guard !batch.isEmpty else { return [] }
        let body = try JSONEncoder().encode(ActionsBody(client_id: device.client_id, device_name: Self.deviceName, actions: batch.map {
            .init(id: $0.id, sequence: $0.sequence, entity: $0.entity, field: $0.field, value: $0.value,
                  base_revision: $0.base_revision, changed_at: $0.changed_at)
        }))
        do {
            return try await client.json(ActionsResponse.self, "/sync/actions", method: "POST", body: body, timeout: 120).results
        } catch SyncError.http(let status, let detail) where [400, 409, 422].contains(status) {
            // One bad change must not block the rest: isolate it.
            if batch.count == 1 {
                return [ActionResult(id: batch[0].id, status: "rejected", revision: 0,
                                     error: detail.isEmpty ? "The Mac rejected this change." : detail)]
            }
            var results: [ActionResult] = []
            for operation in batch { results += try await post([operation]) }
            return results
        }
    }

    /// Ask the Mac to refresh every feed now, then pull the result.
    func refreshFeeds() async {
        do {
            let (data, http) = try await client.request("/refresh", method: "POST", body: Data("{}".utf8), timeout: 120)
            if !(200..<300).contains(http.statusCode) { throw MacClient.failure(http.statusCode, data) }
        } catch { lastError = error.localizedDescription }
        await synchronizeAndWait()
    }

    static let deviceName: String = UIDevice.current.userInterfaceIdiom == .pad ? "iPad app" : "iPhone app"
}
