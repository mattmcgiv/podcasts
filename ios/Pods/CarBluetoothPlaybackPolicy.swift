import AVFoundation
import Foundation
import MediaPlayer

/// One Bluetooth (or CarPlay) output, identified by the system port UID and name.
/// Tesla HFP and A2DP often share a MAC prefix with different UID suffixes; AirPods
/// are also A2DP, so kind + identity must both be checked before auto-resume.
struct CarBluetoothRouteDescriptor: Equatable, Codable {
    var uid: String
    var name: String
    var portTypeRaw: String

    init(uid: String, name: String, portType: AVAudioSession.Port) {
        self.uid = uid
        self.name = name
        self.portTypeRaw = portType.rawValue
    }

    init(_ port: AVAudioSessionPortDescription) {
        self.init(uid: port.uid, name: port.portName, portType: port.portType)
    }

    var portType: AVAudioSession.Port {
        AVAudioSession.Port(rawValue: portTypeRaw)
    }

    var kind: CarBluetoothDeviceKind {
        CarBluetoothPlaybackPolicy.deviceKind(portType: portType, name: name)
    }

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Stable device key: Bluetooth MAC prefix when the UID looks like
    /// `aa:bb:cc:dd:ee:ff-tacl`, otherwise the full UID.
    var stableDeviceKey: String {
        let lower = uid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let macColon = #"([0-9a-f]{2}:){5}[0-9a-f]{2}"#
        if let match = lower.range(of: macColon, options: .regularExpression) {
            return String(lower[match])
        }
        let macDash = #"([0-9a-f]{2}-){5}[0-9a-f]{2}"#
        if let match = lower.range(of: macDash, options: .regularExpression) {
            return String(lower[match]).replacingOccurrences(of: "-", with: ":")
        }
        if !lower.isEmpty { return lower }
        return normalizedName
    }

    func matches(_ other: CarBluetoothRouteDescriptor) -> Bool {
        let a = stableDeviceKey
        let b = other.stableDeviceKey
        if !a.isEmpty, a == b { return true }
        // Same Tesla name across HFP/A2DP when UIDs do not share a MAC prefix.
        if kind == .car, other.kind == .car,
           !normalizedName.isEmpty, normalizedName == other.normalizedName {
            return true
        }
        return false
    }
}

enum CarBluetoothDeviceKind: Equatable {
    case car
    case headphone
    case otherBluetooth
    case notBluetooth
}

/// Armed auto-resume for one classified car device and one episode, with a TTL.
struct CarBluetoothResumeIntent: Equatable, Codable {
    var device: CarBluetoothRouteDescriptor
    var episodeID: Int64?
    var armedAt: TimeInterval
}

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
    var resumeIntent: CarBluetoothResumeIntent?
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
/// Auto-resume is a finite state machine:
/// - Arm only when a **classified car** route is lost while playing (or that
///   same car is already armed). AirPods / speakers / wired headphones never arm.
/// - Consume only when a route matching that **device identity** returns, the
///   armed episode is still loaded, and the intent is inside the TTL.
/// - Playing onto a newly appeared car (get-in-the-car hop) re-asserts play
///   after settle, still bound to that car identity + current episode.
enum CarBluetoothPlaybackPolicy {
    /// Tesla connects HFP before A2DP. Resume after this hop, not on HFP-only.
    static let resumeSettleDelay: TimeInterval = 0.7

    /// Same-day / next-morning commute, not an indefinite "any Bluetooth" latch.
    static let resumeIntentTTL: TimeInterval = 18 * 60 * 60

    static let carSkipInterval: TimeInterval = 30

    private static let headphoneNameTokens = [
        "airpods", "airpod", "earpods", "earbuds", "earphone", "headset",
        "headphone", "beats", "quietcomfort", "qc35", "qc45", "qc ultra",
        "wh-1000", "wh-720", "wf-1000", "linkbuds", "pixel buds", "galaxy buds",
        "freebuds", "nothing ear"
    ]

    private static let carNameTokens = [
        "tesla", "model 3", "model y", "model s", "model x", "cybertruck",
        "carplay", "car stereo", "car audio", "vehicle", "automotive"
    ]

    static func deviceKind(portType: AVAudioSession.Port, name: String) -> CarBluetoothDeviceKind {
        if portType == .headphones { return .headphone }
        if portType == .builtInSpeaker || portType == .builtInReceiver { return .notBluetooth }

        if nameContainsToken(name, tokens: headphoneNameTokens) {
            return .headphone
        }
        if portType == .carAudio || nameContainsToken(name, tokens: carNameTokens) {
            return .car
        }
        if isBluetoothPort(portType) {
            return .otherBluetooth
        }
        return .notBluetooth
    }

    static func isBluetoothPort(_ type: AVAudioSession.Port) -> Bool {
        switch type {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio:
            return true
        default:
            return false
        }
    }

    static func cars(in routes: [CarBluetoothRouteDescriptor]) -> [CarBluetoothRouteDescriptor] {
        routes.filter { $0.kind == .car }
    }

    static func lostCars(
        previous: [CarBluetoothRouteDescriptor],
        current: [CarBluetoothRouteDescriptor]
    ) -> [CarBluetoothRouteDescriptor] {
        cars(in: previous).filter { lost in
            !current.contains { $0.matches(lost) }
        }
    }

    static func validatedIntent(
        _ intent: CarBluetoothResumeIntent?,
        now: TimeInterval,
        ttl: TimeInterval = resumeIntentTTL
    ) -> CarBluetoothResumeIntent? {
        guard let intent else { return nil }
        guard intent.device.kind == .car else { return nil }
        guard now >= intent.armedAt, now - intent.armedAt <= ttl else { return nil }
        return intent
    }

    enum ResumeAction: Equatable {
        case none
        case remember(CarBluetoothResumeIntent)
        case schedule(CarBluetoothResumeIntent)
        case clear
    }

    static func action(
        reason: AVAudioSession.RouteChangeReason,
        previousRoutes: [CarBluetoothRouteDescriptor],
        currentRoutes: [CarBluetoothRouteDescriptor],
        hasActiveContent: Bool,
        isPlaying: Bool,
        intent: CarBluetoothResumeIntent?,
        currentEpisodeID: Int64?,
        isLocalOutput: Bool,
        now: TimeInterval
    ) -> ResumeAction {
        guard isLocalOutput, hasActiveContent else { return .none }

        let validIntent = validatedIntent(intent, now: now)

        switch reason {
        case .oldDeviceUnavailable:
            guard let lost = lostCars(previous: previousRoutes, current: currentRoutes).first else {
                return .none
            }
            let alreadyArmedForThisCar = validIntent.map { lost.matches($0.device) } ?? false
            guard isPlaying || alreadyArmedForThisCar else { return .none }
            return .remember(
                CarBluetoothResumeIntent(
                    device: lost,
                    episodeID: currentEpisodeID,
                    armedAt: now
                )
            )

        case .newDeviceAvailable, .routeConfigurationChange:
            let currentCars = cars(in: currentRoutes)
            if currentCars.isEmpty {
                if intent != nil, validIntent == nil { return .clear }
                return .none
            }

            if isPlaying, let car = currentCars.first {
                return .schedule(
                    CarBluetoothResumeIntent(
                        device: car,
                        episodeID: currentEpisodeID,
                        armedAt: validIntent?.armedAt ?? now
                    )
                )
            }

            if let validIntent,
               let car = currentCars.first(where: { $0.matches(validIntent.device) }) {
                return .schedule(
                    CarBluetoothResumeIntent(
                        device: car,
                        episodeID: validIntent.episodeID ?? currentEpisodeID,
                        armedAt: validIntent.armedAt
                    )
                )
            }

            if intent != nil, validIntent == nil {
                return .clear
            }
            return .none

        default:
            if intent != nil, validIntent == nil {
                return .clear
            }
            return .none
        }
    }

    static func shouldCommitScheduledResume(
        scheduled: CarBluetoothResumeIntent,
        currentRoutes: [CarBluetoothRouteDescriptor],
        currentEpisodeID: Int64?,
        isLocalOutput: Bool,
        now: TimeInterval
    ) -> Bool {
        guard isLocalOutput else { return false }
        guard validatedIntent(scheduled, now: now) != nil else { return false }
        if let armedEpisode = scheduled.episodeID, armedEpisode != currentEpisodeID {
            return false
        }
        return currentRoutes.contains { $0.kind == .car && $0.matches(scheduled.device) }
    }

    static func shouldResumeAfterInterruption(
        shouldResumeOption: Bool,
        wasPlayingBeforeInterruption: Bool,
        currentCarMatchesArmedIntent: Bool,
        isLocalOutput: Bool
    ) -> Bool {
        guard isLocalOutput else { return false }
        if shouldResumeOption && wasPlayingBeforeInterruption {
            return true
        }
        return currentCarMatchesArmedIntent && wasPlayingBeforeInterruption
    }

    static func currentCarMatchesIntent(
        routes: [CarBluetoothRouteDescriptor],
        intent: CarBluetoothResumeIntent?,
        now: TimeInterval
    ) -> Bool {
        guard let intent = validatedIntent(intent, now: now) else { return false }
        return routes.contains { $0.kind == .car && $0.matches(intent.device) }
    }

    private static func nameContainsToken(_ name: String, tokens: [String]) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !n.isEmpty else { return false }
        return tokens.contains { token in
            if token.contains(" ") || token.contains("-") {
                return n.contains(token)
            }
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: token))\\b"
            return n.range(of: pattern, options: .regularExpression) != nil
        }
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
