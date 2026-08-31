import AVFoundation
import Foundation
import MediaPlayer

/// Durable now-playing session so a Tesla / car Bluetooth connect can resume
/// after iOS jetsams the process. Publisher URL (not the resolved local file)
/// is restored so ad-removal source selection runs again.
struct CarBluetoothSessionSnapshot: Equatable, Codable {
    var episodeID: Int64
    var publisherURL: String
    var position: Double
    var rate: Float
    var title: String?
    var artist: String?
    var artworkURL: String?
    var duration: Double?
    var resumeWhenCarConnects: Bool
}

protocol CarBluetoothSessionStoring: AnyObject {
    func save(_ snapshot: CarBluetoothSessionSnapshot)
    func load() -> CarBluetoothSessionSnapshot?
    func clear()
}

final class UserDefaultsCarBluetoothSessionStore: CarBluetoothSessionStoring {
    static let defaultsKey = "pods.carBluetooth.session"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ snapshot: CarBluetoothSessionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func load() -> CarBluetoothSessionSnapshot? {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(CarBluetoothSessionSnapshot.self, from: data)
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

/// Pure rules for Tesla-style car Bluetooth (A2DP + AVRCP, no CarPlay).
///
/// The iPhone session must identify as long-form spoken audio. Tesla then:
/// 1. Routes media to the car stereo (A2DP; HFP appears first during handshake).
/// 2. Sends AVRCP play / pause / next / previous / seek.
/// 3. Renders Now Playing title, artwork, and progress.
///
/// iOS does **not** auto-resume `.spokenAudio` on `newDeviceAvailable`. The
/// previous handler only refreshed Now Playing, so getting in the car left
/// playback paused. This policy decides when to remember resume intent (BT
/// lost while playing) and when to restart after the HFP→A2DP hop settles.
enum CarBluetoothPlaybackPolicy {
    /// Tesla connects HFP before A2DP. Resume after this hop, not on HFP-only.
    static let resumeSettleDelay: TimeInterval = 0.7

    static let carSkipInterval: TimeInterval = 30

    static func isCarBluetoothPort(_ type: AVAudioSession.Port) -> Bool {
        switch type {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio:
            return true
        default:
            return false
        }
    }

    static func routeHasCarBluetooth(_ portTypes: [AVAudioSession.Port]) -> Bool {
        portTypes.contains(where: isCarBluetoothPort)
    }

    /// Media-quality car output. HFP-only is the Tesla phone-profile handshake.
    static func routeIsPreferredCarMedia(_ portTypes: [AVAudioSession.Port]) -> Bool {
        portTypes.contains { $0 == .bluetoothA2DP || $0 == .carAudio }
    }

    enum ResumeAction: Equatable {
        case none
        case rememberResume
        case scheduleResume
    }

    static func action(
        reason: AVAudioSession.RouteChangeReason,
        previousHadCarBluetooth: Bool,
        currentHasCarBluetooth: Bool,
        hasActiveContent: Bool,
        isPlaying: Bool,
        resumeWhenCarConnects: Bool,
        isLocalOutput: Bool
    ) -> ResumeAction {
        guard isLocalOutput, hasActiveContent else { return .none }

        switch reason {
        case .oldDeviceUnavailable:
            if previousHadCarBluetooth && (isPlaying || resumeWhenCarConnects) {
                return .rememberResume
            }
            return .none

        case .newDeviceAvailable, .routeConfigurationChange:
            guard currentHasCarBluetooth else { return .none }
            if isPlaying || resumeWhenCarConnects {
                return .scheduleResume
            }
            return .none

        default:
            return .none
        }
    }

    /// After settle, resume if any car/Bluetooth output is still the route.
    /// Tesla Model 3 sometimes keeps reporting HFP even after A2DP media is up;
    /// requiring A2DP-only would miss those connects. The settle delay is what
    /// skips the initial HFP handshake, not the port-type filter.
    static func shouldCommitScheduledResume(
        currentHasCarBluetooth: Bool,
        hasActiveContent: Bool,
        isLocalOutput: Bool
    ) -> Bool {
        isLocalOutput && hasActiveContent && currentHasCarBluetooth
    }

    static func shouldResumeAfterInterruption(
        shouldResumeOption: Bool,
        currentIsPreferredCarMedia: Bool,
        wasPlayingBeforeInterruption: Bool,
        resumeWhenCarConnects: Bool,
        isLocalOutput: Bool
    ) -> Bool {
        guard isLocalOutput else { return false }
        if shouldResumeOption && wasPlayingBeforeInterruption {
            return true
        }
        // Tesla HFP connect often ends the interruption *without* shouldResume.
        return currentIsPreferredCarMedia && (wasPlayingBeforeInterruption || resumeWhenCarConnects)
    }

    static func nextResumeIntent(
        current: Bool,
        userInitiatedPause: Bool,
        startedPlaying: Bool,
        clearedSession: Bool
    ) -> Bool {
        if clearedSession || userInitiatedPause { return false }
        if startedPlaying { return true }
        return current
    }
}

/// Absolute-seek policy for Tesla / lock-screen scrubber (AVRCP SetAbsolute).
enum RemotePlaybackPositionHandler {
    static func handle(
        hasActiveContent: Bool,
        position: TimeInterval,
        knownDuration: Double?,
        absoluteSeek: (Double) -> Void
    ) -> MPRemoteCommandHandlerStatus {
        guard hasActiveContent else {
            return .noActionableNowPlayingItem
        }
        guard position.isFinite else {
            return .commandFailed
        }

        var target = max(0, position)
        if let duration = knownDuration, duration.isFinite, duration > 0 {
            target = min(target, duration)
        }
        absoluteSeek(target)
        return .success
    }
}
