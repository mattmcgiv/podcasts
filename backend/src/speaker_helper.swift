import AVFoundation
import CoreMedia
import Darwin
import Foundation

/// Headless AVFoundation player. JSON lines on stdin, JSON lines on stdout.
/// Rust owns authorization and path validation. This process only plays local files.
@main
enum PodsSpeakerHelper {
    static func main() {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        let engine = Engine()
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                engine.handleLine(line)
            }
            engine.quit()
        }
        RunLoop.main.run()
    }
}

final class Engine: NSObject {
    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var tick: Timer?
    private var duration: Double = 0
    private var ended = false
    private var lastError: String?
    private var requestedRate: Float = 1
    private var muted = false
    private var loadGeneration: UInt64 = 0
    private var lastCommandId: UInt64 = 0
    private var finishedLoadGeneration: UInt64 = 0

    override init() {
        super.init()
        player.volume = 1
        player.actionAtItemEnd = .pause
        if #available(macOS 12.0, *) {
            player.preventsDisplaySleepDuringVideoPlayback = false
        }
    }

    func handleLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["cmd"] as? String
        else {
            emit(type: "error", id: 0, generation: loadGeneration, error: "Invalid speaker command.")
            return
        }
        DispatchQueue.main.async { self.handle(cmd: cmd, body: obj) }
    }

    private func handle(cmd: String, body: [String: Any]) {
        let id = uintValue(body["id"]) ?? 0
        lastCommandId = id
        switch cmd {
        case "load":
            load(body, id: id)
        case "play":
            play(id: id)
        case "pause":
            pause(id: id)
        case "seek":
            seek(doubleValue(body["seconds"]) ?? 0, id: id)
        case "rate":
            setRate(floatValue(body["rate"]) ?? 1, id: id)
        case "stop":
            stop(id: id)
        case "quit":
            quit()
        default:
            emit(type: "error", id: id, generation: loadGeneration, error: "Unknown speaker command.")
        }
    }

    private func load(_ body: [String: Any], id: UInt64) {
        loadGeneration &+= 1
        let generation = uintValue(body["generation"]) ?? loadGeneration
        loadGeneration = generation
        ended = false
        lastError = nil
        duration = 0
        finishedLoadGeneration = 0
        let position = max(0, doubleValue(body["position"]) ?? 0)
        requestedRate = normalizedRate(floatValue(body["rate"]) ?? 1)
        muted = boolValue(body["mute"])
        player.volume = muted ? 0 : 1

        guard let path = body["path"] as? String, isLocalFilePath(path) else {
            emit(type: "error", id: id, generation: generation, error: "Mac could not play this episode.")
            return
        }
        let url = URL(fileURLWithPath: path)
        guard url.isFileURL else {
            emit(type: "error", id: id, generation: generation, error: "Mac could not play this episode.")
            return
        }

        clearObservers()
        player.pause()
        player.rate = 0
        player.replaceCurrentItem(with: nil)

        let item = AVPlayerItem(url: url)
        observe(item, generation: generation, id: id)
        player.volume = muted ? 0 : 1
        let finishLoad: () -> Void = { [weak self] in
            guard let self, self.loadGeneration == generation, self.finishedLoadGeneration != generation else { return }
            self.finishedLoadGeneration = generation
            self.statusObservation?.invalidate()
            self.statusObservation = nil
            self.refreshDuration()
            let complete = { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.refreshDuration()
                self.emit(type: "ack", id: id, generation: generation, error: nil)
            }
            if position > 0 {
                let time = CMTime(seconds: position, preferredTimescale: 600)
                self.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    guard finished else { return }
                    DispatchQueue.main.async { complete() }
                }
            } else {
                complete()
            }
        }
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation else { return }
                if item.status == .readyToPlay {
                    finishLoad()
                } else if item.status == .failed {
                    self.statusObservation?.invalidate()
                    self.statusObservation = nil
                    self.lastError = "Mac could not play this episode."
                    self.emit(type: "error", id: id, generation: generation, error: self.lastError)
                }
            }
        }
        player.replaceCurrentItem(with: item)
    }

    private func play(id: UInt64) {
        let generation = loadGeneration
        guard player.currentItem != nil else {
            emit(type: "error", id: id, generation: generation, error: "Mac speaker disconnected.")
            return
        }
        ended = false
        lastError = nil
        player.volume = muted ? 0 : 1
        player.playImmediately(atRate: requestedRate)
        startTick()
        emit(type: "ack", id: id, generation: generation, error: nil)
    }

    private func pause(id: UInt64) {
        let generation = loadGeneration
        player.pause()
        player.rate = 0
        stopTick()
        emit(type: "ack", id: id, generation: generation, error: nil)
    }

    private func seek(_ seconds: Double, id: UInt64) {
        let generation = loadGeneration
        let target = max(0, seconds.isFinite ? seconds : 0)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self, finished, self.loadGeneration == generation else { return }
            self.emit(type: "ack", id: id, generation: generation, error: nil)
        }
    }

    private func setRate(_ rate: Float, id: UInt64) {
        let generation = loadGeneration
        requestedRate = normalizedRate(rate)
        if player.rate != 0 {
            player.rate = requestedRate
        }
        emit(type: "ack", id: id, generation: generation, error: nil)
    }

    private func stop(id: UInt64) {
        let generation = loadGeneration
        stopTick()
        player.pause()
        player.rate = 0
        emit(type: "ack", id: id, generation: generation, error: nil)
        player.replaceCurrentItem(with: nil)
        clearObservers()
        duration = 0
        ended = false
        lastError = nil
    }

    func quit() {
        DispatchQueue.main.async {
            self.stopTick()
            self.player.pause()
            self.player.replaceCurrentItem(with: nil)
            self.clearObservers()
            exit(0)
        }
    }

    private func observe(_ item: AVPlayerItem, generation: UInt64, id: UInt64) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.loadGeneration == generation else { return }
            self.ended = true
            self.player.pause()
            self.player.rate = 0
            self.stopTick()
            self.emit(type: "ended", id: id, generation: generation, error: nil)
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.loadGeneration == generation else { return }
            self.lastError = "Mac could not play this episode."
            self.player.pause()
            self.stopTick()
            self.emit(type: "error", id: id, generation: generation, error: self.lastError)
        }
    }

    private func clearObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = nil
        failObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
    }

    private func startTick() {
        stopTick()
        let generation = loadGeneration
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.loadGeneration == generation else { return }
            self.refreshDuration()
            self.emit(type: "state", id: self.lastCommandId, generation: generation, error: nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func stopTick() {
        tick?.invalidate()
        tick = nil
    }

    private func refreshDuration() {
        guard let item = player.currentItem else { return }
        let times = [item.duration, item.asset.duration]
        for time in times {
            if time.isNumeric, time.seconds.isFinite, time.seconds > 0 {
                duration = time.seconds
                return
            }
        }
    }

    private func emit(type: String, id: UInt64, generation: UInt64, error: String?) {
        refreshDuration()
        let seconds = player.currentTime().seconds
        let position = seconds.isFinite ? max(0, seconds) : 0
        let paused = player.rate == 0
        var payload: [String: Any] = [
            "type": type,
            "id": id,
            "generation": generation,
            "position": position,
            "duration": duration,
            "paused": paused,
            "ended": ended,
            "rate": Double(player.rate == 0 ? requestedRate : player.rate),
        ]
        if let error {
            payload["error"] = publicError(error)
        }
        guard JSONSerialization.isValidJSONObject(payload),
              var data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        if let out = line.data(using: .utf8) {
            FileHandle.standardOutput.write(out)
        }
        fflush(stdout)
    }

    private func isLocalFilePath(_ path: String) -> Bool {
        if path.isEmpty || path.count > 1024 { return false }
        if path.contains("\0") || path.contains("..") { return false }
        if !path.hasPrefix("/") { return false }
        let lower = path.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return false }
        if lower.hasPrefix("blob:") || lower.hasPrefix("data:") { return false }
        if lower.hasPrefix("file:") { return false }
        return true
    }
}

private func publicError(_ raw: String) -> String {
    let lower = raw.lowercased()
    if lower.contains("/") || lower.contains(".m4a") || lower.contains("users") || lower.contains("token") {
        return "Mac could not play this episode."
    }
    let clipped = String(raw.prefix(160))
    return clipped.isEmpty ? "Mac speaker failed." : clipped
}

private func doubleValue(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    return nil
}

private func floatValue(_ value: Any?) -> Float? {
    if let value = value as? Float { return value }
    if let value = value as? Double { return Float(value) }
    if let value = value as? NSNumber { return value.floatValue }
    return nil
}

private func uintValue(_ value: Any?) -> UInt64? {
    if let value = value as? UInt64 { return value }
    if let value = value as? Int { return UInt64(value) }
    if let value = value as? NSNumber { return value.uint64Value }
    return nil
}

private func boolValue(_ value: Any?) -> Bool {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    return false
}

private func normalizedRate(_ value: Float) -> Float {
    value.isFinite && value >= 0.5 && value <= 3 ? value : 1
}
