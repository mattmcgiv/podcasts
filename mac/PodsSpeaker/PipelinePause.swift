import Foundation

/// On-disk state for the menu-bar pause of local inference.
///
/// The Rust backend reads the same file (`pipeline-pause.json`) and refuses to
/// start Whisper, classification, or show notes while `pauseUntil` is in the
/// future. `pausedAt + limitSeconds` is the hard four-hour cap.
struct PipelinePauseState: Codable, Equatable {
    let pausedAt: Int
    let pauseUntil: Int

    static let limitSeconds = 4 * 60 * 60

    enum CodingKeys: String, CodingKey {
        case pausedAt = "paused_at"
        case pauseUntil = "pause_until"
    }

    init(pausedAt: Date) {
        let epoch = Int(pausedAt.timeIntervalSince1970)
        self.pausedAt = epoch
        self.pauseUntil = epoch + Self.limitSeconds
    }

    var pausedAtDate: Date { Date(timeIntervalSince1970: TimeInterval(pausedAt)) }
    var pauseUntilDate: Date { Date(timeIntervalSince1970: TimeInterval(pauseUntil)) }

    func isActive(at now: Date) -> Bool {
        now < pauseUntilDate
    }
}

enum PipelinePauseFile {
    static let fileName = "pipeline-pause.json"

    static var defaultURL: URL {
        if let dir = ProcessInfo.processInfo.environment["PODS_STATE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(fileName)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/pods", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Strictly decode: an inverted or malformed interval is not a pause.
    static func decode(_ data: Data) -> PipelinePauseState? {
        guard let state = try? JSONDecoder().decode(PipelinePauseState.self, from: data) else {
            return nil
        }
        guard state.pauseUntil > state.pausedAt else { return nil }
        return state
    }

    static func read(from url: URL) -> PipelinePauseState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func write(_ state: PipelinePauseState, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    static func clear(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

@MainActor
final class PipelinePauseController: ObservableObject {
    @Published private(set) var isPaused = false
    @Published private(set) var pauseUntil: Date?

    let fileURL: URL
    private var expiryTimer: Timer?

    init(fileURL: URL = PipelinePauseFile.defaultURL, now: Date = Date()) {
        self.fileURL = fileURL
        refresh(now: now)
    }

    var remaining: TimeInterval? {
        pauseUntil.map { max(0, $0.timeIntervalSinceNow) }
    }

    /// Re-read the shared file. An expired pause is cleared and reported off.
    func refresh(now: Date = Date()) {
        if let state = PipelinePauseFile.read(from: fileURL), state.isActive(at: now) {
            isPaused = true
            pauseUntil = state.pauseUntilDate
            scheduleExpiry(now: now)
            return
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            PipelinePauseFile.clear(at: fileURL)
        }
        isPaused = false
        pauseUntil = nil
        cancelTimer()
    }

    func setPaused(_ paused: Bool, now: Date = Date()) {
        guard paused else {
            PipelinePauseFile.clear(at: fileURL)
            isPaused = false
            pauseUntil = nil
            cancelTimer()
            return
        }
        do {
            let state = PipelinePauseState(pausedAt: now)
            try PipelinePauseFile.write(state, to: fileURL)
            isPaused = true
            pauseUntil = state.pauseUntilDate
            scheduleExpiry(now: now)
        } catch {
            isPaused = false
            pauseUntil = nil
            cancelTimer()
        }
    }

    static func formatRemaining(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(max(1, minutes))m"
    }

    private func scheduleExpiry(now: Date) {
        cancelTimer()
        guard let pauseUntil else { return }
        let interval = max(0, pauseUntil.timeIntervalSince(now))
        expiryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func cancelTimer() {
        expiryTimer?.invalidate()
        expiryTimer = nil
    }
}
