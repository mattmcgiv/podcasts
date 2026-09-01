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
    /// MAC / stable keys previously observed as a car (including a custom-named
    /// Tesla that first appeared as HFP). Missing in snapshots written before #9.
    var knownCarDeviceKeys: [String]

    init(
        episodeID: Int64,
        publisherURL: String,
        position: Double,
        rate: Float,
        title: String? = nil,
        artist: String? = nil,
        artworkURL: String? = nil,
        duration: Double? = nil,
        resumeIntent: CarBluetoothResumeIntent? = nil,
        knownCarDeviceKeys: [String] = []
    ) {
        self.episodeID = episodeID
        self.publisherURL = publisherURL
        self.position = position
        self.rate = rate
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.duration = duration
        self.resumeIntent = resumeIntent
        self.knownCarDeviceKeys = knownCarDeviceKeys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        episodeID = try container.decode(Int64.self, forKey: .episodeID)
        publisherURL = try container.decode(String.self, forKey: .publisherURL)
        position = try container.decode(Double.self, forKey: .position)
        rate = try container.decode(Float.self, forKey: .rate)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        artworkURL = try container.decodeIfPresent(String.self, forKey: .artworkURL)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        resumeIntent = try container.decodeIfPresent(CarBluetoothResumeIntent.self, forKey: .resumeIntent)
        knownCarDeviceKeys = try container.decodeIfPresent([String].self, forKey: .knownCarDeviceKeys) ?? []
    }
}

/// Extra signals used to promote a custom-named Tesla A2DP port to `.car`.
/// Vehicle Bluetooth names are often the owner's car name ("Midnight"), not
/// "Tesla Model 3". HFP on the same MAC — as an output or an available input —
/// is the hands-free unit; portable speakers are A2DP-only.
struct CarBluetoothRouteContext: Equatable {
    var knownCarDeviceKeys: Set<String>
    var handsFreeDeviceKeys: Set<String>

    static let empty = CarBluetoothRouteContext(knownCarDeviceKeys: [], handsFreeDeviceKeys: [])

    static func handsFreeDeviceKeys(from routes: [CarBluetoothRouteDescriptor]) -> Set<String> {
        Set(
            routes
                .filter { $0.portType == .bluetoothHFP && $0.kind != .headphone }
                .map(\.stableDeviceKey)
        )
    }
}

protocol CarBluetoothSessionStoring: AnyObject {
    func save(_ snapshot: CarBluetoothSessionSnapshot)
    func load() -> CarBluetoothSessionSnapshot?
    func clear()
    func saveKnownCarDeviceKeys(_ keys: [String])
    func loadKnownCarDeviceKeys() -> [String]
}

final class UserDefaultsCarBluetoothSessionStore: CarBluetoothSessionStoring {
    static let defaultsKey = "pods.carBluetooth.session"
    static let knownCarsKey = "pods.carBluetooth.knownCars"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ snapshot: CarBluetoothSessionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
        saveKnownCarDeviceKeys(snapshot.knownCarDeviceKeys)
    }

    func load() -> CarBluetoothSessionSnapshot? {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return nil }
        guard var snapshot = try? JSONDecoder().decode(CarBluetoothSessionSnapshot.self, from: data) else {
            return nil
        }
        if snapshot.knownCarDeviceKeys.isEmpty {
            snapshot.knownCarDeviceKeys = loadKnownCarDeviceKeys()
        }
        return snapshot
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    func saveKnownCarDeviceKeys(_ keys: [String]) {
        let unique = Array(Set(keys)).sorted()
        if unique.isEmpty {
            return
        }
        defaults.set(unique, forKey: Self.knownCarsKey)
    }

    func loadKnownCarDeviceKeys() -> [String] {
        defaults.stringArray(forKey: Self.knownCarsKey) ?? []
    }
}

/// Pure rules for Tesla-style car Bluetooth (A2DP + AVRCP, no CarPlay).
///
/// Auto-resume is a finite state machine:
/// - Arm only when a **classified car** route is lost while playing (or that
///   same car is already armed). AirPods / speakers / wired headphones never arm.
/// - Consume when a route matching that **device identity** returns, the armed
///   episode is still loaded, and the intent is inside the TTL.
/// - **Commit on the matching car, including HFP.** Tesla Model 3 often holds
///   HFP-only until the phone starts playback; waiting for A2DP deadlocks
///   (the car never opens stereo / never sends AVRCP play). `play()` after
///   settle is what completes the media hop. AirPods stay excluded by name.
/// - Playing onto a newly appeared car (get-in-the-car hop) re-asserts play
///   after settle, still bound to that car identity + current episode.
enum CarBluetoothPlaybackPolicy {
    /// Let Tesla finish the HFP bounce, then play so A2DP can come up.
    static let resumeSettleDelay: TimeInterval = 1.2

    /// Same-day / next-morning commute, not an indefinite "any Bluetooth" latch.
    static let resumeIntentTTL: TimeInterval = 18 * 60 * 60

    /// Silent session keep-alive after leaving the car so iOS keeps delivering
    /// route-change notifications. Next-morning resume uses persist + AVRCP +
    /// foreground, not 18 hours of silent audio.
    static let resumeKeepAliveDuration: TimeInterval = 20 * 60

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
        // Tesla's Bluetooth name is often the vehicle name ("Midnight"), not
        // "Tesla Model 3". Non-headphone HFP is a hands-free unit (car), not
        // a portable speaker — those are A2DP-only.
        if portType == .bluetoothHFP {
            return .car
        }
        if isBluetoothPort(portType) {
            return .otherBluetooth
        }
        return .notBluetooth
    }

    static func isCar(
        _ route: CarBluetoothRouteDescriptor,
        context: CarBluetoothRouteContext = .empty
    ) -> Bool {
        switch route.kind {
        case .car:
            return true
        case .headphone, .notBluetooth:
            return false
        case .otherBluetooth:
            let key = route.stableDeviceKey
            return context.knownCarDeviceKeys.contains(key)
                || context.handsFreeDeviceKeys.contains(key)
        }
    }

    static func isBluetoothPort(_ type: AVAudioSession.Port) -> Bool {
        switch type {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio:
            return true
        default:
            return false
        }
    }

    static func cars(
        in routes: [CarBluetoothRouteDescriptor],
        context: CarBluetoothRouteContext = .empty
    ) -> [CarBluetoothRouteDescriptor] {
        routes.filter { isCar($0, context: context) }
    }

    /// Stereo / CarPlay media. Tesla HFP is still the same car for identity
    /// and for commit — play() is what pulls A2DP up on Model 3.
    static func isMediaCapableCarRoute(
        _ route: CarBluetoothRouteDescriptor,
        context: CarBluetoothRouteContext = .empty
    ) -> Bool {
        guard isCar(route, context: context) else { return false }
        return route.portType == .bluetoothA2DP || route.portType == .carAudio
    }

    static func hasMatchingCar(
        matching device: CarBluetoothRouteDescriptor,
        in routes: [CarBluetoothRouteDescriptor],
        context: CarBluetoothRouteContext = .empty
    ) -> Bool {
        routes.contains { isCar($0, context: context) && $0.matches(device) }
    }

    static func hasMediaCapableCar(
        matching device: CarBluetoothRouteDescriptor,
        in routes: [CarBluetoothRouteDescriptor],
        context: CarBluetoothRouteContext = .empty
    ) -> Bool {
        routes.contains { isMediaCapableCarRoute($0, context: context) && $0.matches(device) }
    }

    static func lostCars(
        previous: [CarBluetoothRouteDescriptor],
        current: [CarBluetoothRouteDescriptor],
        context: CarBluetoothRouteContext = .empty
    ) -> [CarBluetoothRouteDescriptor] {
        cars(in: previous, context: context).filter { lost in
            !current.contains { $0.matches(lost) }
        }
    }

    static func discoveredCarDeviceKeys(
        routes: [CarBluetoothRouteDescriptor],
        context: CarBluetoothRouteContext = .empty
    ) -> [String] {
        var keys = context.knownCarDeviceKeys.union(context.handsFreeDeviceKeys)
        for route in cars(in: routes, context: context) {
            keys.insert(route.stableDeviceKey)
        }
        return keys.sorted()
    }

    /// Persist an identity whose `kind` stays `.car` after the live HFP pairing
    /// is gone. Custom-named Tesla A2DP is `.otherBluetooth` until promoted;
    /// storing that descriptor made `validatedIntent` drop the latch on reconnect.
    static func rememberedCarDevice(
        _ route: CarBluetoothRouteDescriptor,
        context: CarBluetoothRouteContext = .empty
    ) -> CarBluetoothRouteDescriptor {
        if route.kind == .car { return route }
        guard isCar(route, context: context) else { return route }
        return CarBluetoothRouteDescriptor(
            uid: route.uid,
            name: route.name,
            portType: .bluetoothHFP
        )
    }

    static func validatedIntent(
        _ intent: CarBluetoothResumeIntent?,
        now: TimeInterval,
        ttl: TimeInterval = resumeIntentTTL,
        context: CarBluetoothRouteContext = .empty
    ) -> CarBluetoothResumeIntent? {
        guard let intent else { return nil }
        guard isCar(intent.device, context: context) else { return nil }
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
        now: TimeInterval,
        context: CarBluetoothRouteContext = .empty
    ) -> ResumeAction {
        guard isLocalOutput, hasActiveContent else { return .none }

        let validIntent = validatedIntent(intent, now: now, context: context)

        switch reason {
        case .oldDeviceUnavailable:
            guard let lost = lostCars(
                previous: previousRoutes,
                current: currentRoutes,
                context: context
            ).first else {
                return .none
            }
            let alreadyArmedForThisCar = validIntent.map { lost.matches($0.device) } ?? false
            guard isPlaying || alreadyArmedForThisCar else { return .none }
            return .remember(
                CarBluetoothResumeIntent(
                    device: rememberedCarDevice(lost, context: context),
                    episodeID: currentEpisodeID,
                    armedAt: now
                )
            )

        case .newDeviceAvailable, .routeConfigurationChange:
            let currentCars = cars(in: currentRoutes, context: context)
            if currentCars.isEmpty {
                if intent != nil, validIntent == nil { return .clear }
                return .none
            }

            if isPlaying, let car = currentCars.first {
                return .schedule(
                    CarBluetoothResumeIntent(
                        device: rememberedCarDevice(car, context: context),
                        episodeID: currentEpisodeID,
                        armedAt: validIntent?.armedAt ?? now
                    )
                )
            }

            if let validIntent,
               let car = currentCars.first(where: { $0.matches(validIntent.device) }) {
                return .schedule(
                    CarBluetoothResumeIntent(
                        device: rememberedCarDevice(car, context: context),
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
        now: TimeInterval,
        context: CarBluetoothRouteContext = .empty
    ) -> Bool {
        guard isLocalOutput else { return false }
        guard validatedIntent(scheduled, now: now, context: context) != nil else { return false }
        if let armedEpisode = scheduled.episodeID, armedEpisode != currentEpisodeID {
            return false
        }
        // Model 3 keeps HFP-only until the phone plays. Commit on the matching
        // car identity (HFP or A2DP) after settle so play() can open stereo.
        return hasMatchingCar(matching: scheduled.device, in: currentRoutes, context: context)
    }

    static func shouldKeepSessionAlive(
        intent: CarBluetoothResumeIntent?,
        now: TimeInterval,
        keepAliveDuration: TimeInterval = resumeKeepAliveDuration,
        context: CarBluetoothRouteContext = .empty
    ) -> Bool {
        guard let intent = validatedIntent(intent, now: now, context: context) else { return false }
        return now >= intent.armedAt && now - intent.armedAt <= keepAliveDuration
    }

    static func shouldScheduleResumeOnForeground(
        intent: CarBluetoothResumeIntent?,
        currentRoutes: [CarBluetoothRouteDescriptor],
        hasActiveContent: Bool,
        isLocalOutput: Bool,
        now: TimeInterval,
        context: CarBluetoothRouteContext = .empty
    ) -> Bool {
        guard isLocalOutput, hasActiveContent else { return false }
        guard let intent = validatedIntent(intent, now: now, context: context) else { return false }
        return hasMatchingCar(matching: intent.device, in: currentRoutes, context: context)
    }

    static func shouldPreserveResumeAcrossLoad(
        incomingEpisodeID: Int64?,
        currentEpisodeID: Int64?
    ) -> Bool {
        guard let incomingEpisodeID, let currentEpisodeID else { return false }
        return incomingEpisodeID == currentEpisodeID
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
        now: TimeInterval,
        context: CarBluetoothRouteContext = .empty
    ) -> Bool {
        guard let intent = validatedIntent(intent, now: now, context: context) else { return false }
        return hasMatchingCar(matching: intent.device, in: routes, context: context)
    }

    /// User/system events that must not leave a pending 0.7s callback or a
    /// persisted latch pointing at a different episode or sink.
    enum LifecycleEvent: Equatable {
        case userLoad
        case rebuildSameEpisode
        case sinkChanged
        case manualPlay
        case userPause
        case stop
        case ended
        case expired
    }

    struct LifecycleDecision: Equatable {
        var clearIntent: Bool
        var cancelPending: Bool
    }

    static func lifecycleDecision(for event: LifecycleEvent) -> LifecycleDecision {
        switch event {
        case .userLoad, .sinkChanged, .userPause, .stop, .ended, .expired:
            return LifecycleDecision(clearIntent: true, cancelPending: true)
        case .rebuildSameEpisode, .manualPlay:
            return LifecycleDecision(clearIntent: false, cancelPending: true)
        }
    }

    static func applying(
        _ decision: LifecycleDecision,
        to intent: CarBluetoothResumeIntent?
    ) -> CarBluetoothResumeIntent? {
        decision.clearIntent ? nil : intent
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
