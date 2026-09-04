// DEPRECATED as of 1 October 2026. Do not review, extend, or append to this file.
// See ios/DEPRECATED.md.

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
    /// Persisted enrollment for a custom-named vehicle. Name tokens and
    /// `.carAudio` remain the only intrinsic classifiers; A2DP+HFP pairing
    /// is not a vehicle.
    var enrolledAsVehicle: Bool

    init(
        uid: String,
        name: String,
        portType: AVAudioSession.Port,
        enrolledAsVehicle: Bool = false
    ) {
        self.uid = uid
        self.name = name
        self.portTypeRaw = portType.rawValue
        self.enrolledAsVehicle = enrolledAsVehicle
    }

    init(_ port: AVAudioSessionPortDescription) {
        self.init(uid: port.uid, name: port.portName, portType: port.portType)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        name = try container.decode(String.self, forKey: .name)
        portTypeRaw = try container.decode(String.self, forKey: .portTypeRaw)
        enrolledAsVehicle = try container.decodeIfPresent(Bool.self, forKey: .enrolledAsVehicle) ?? false
    }

    var portType: AVAudioSession.Port {
        AVAudioSession.Port(rawValue: portTypeRaw)
    }

    var kind: CarBluetoothDeviceKind {
        let classified = CarBluetoothPlaybackPolicy.deviceKind(portType: portType, name: name)
        if enrolledAsVehicle, classified != .headphone, classified != .notBluetooth {
            return .car
        }
        return classified
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

/// Extra signals for custom-named Teslas. Vehicle Bluetooth names are often
/// the owner's car name ("Midnight"), not "Tesla Model 3".
///
/// `knownCarDeviceKeys` is the only custom-name enrollment signal. Dual-profile
/// A2DP+HFP pairing (`handsFreeDeviceKeys`) does not prove a vehicle — headsets
/// commonly expose both.
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
            defaults.removeObject(forKey: Self.knownCarsKey)
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
///   Unknown HFP headsets and speakerphones are not cars; a negative name list
///   cannot prove an HFP port is a vehicle. Dual-profile A2DP+HFP pairing
///   also does not prove a vehicle.
/// - Custom-named Teslas use persisted enrollment (`knownCarDeviceKeys` and
///   `enrolledAsVehicle` on the remembered identity). The production path that
///   creates that state is an explicit Settings action (`CarBluetoothEnrollment`),
///   not A2DP+HFP pairing.
/// - Consume when a route matching that **device identity** returns, the armed
///   episode is still loaded, and the intent is inside the TTL.
/// - **Commit on the matching armed identity, including Tesla HFP.** Model 3
///   often holds HFP-only until the phone starts playback; waiting for A2DP
///   deadlocks. `play()` after settle completes the media hop.
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
            return context.knownCarDeviceKeys.contains(route.stableDeviceKey)
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

    /// Consume an already-armed car identity when that MAC returns, including
    /// Tesla HFP-first reconnect. Does not classify unknown HFP as a car.
    static func matchingArmedIdentity(
        routes: [CarBluetoothRouteDescriptor],
        intent: CarBluetoothResumeIntent
    ) -> CarBluetoothRouteDescriptor? {
        routes.first { route in
            route.matches(intent.device)
                && route.kind != .headphone
                && route.kind != .notBluetooth
        }
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
        var keys = context.knownCarDeviceKeys
        for route in routes where isCar(route, context: context) {
            keys.insert(route.stableDeviceKey)
        }
        return keys.sorted()
    }

    /// Persist an enrolled vehicle identity so `kind` stays `.car` after
    /// reconnect, without rewriting the port to HFP (HFP is not intrinsically
    /// a car). Dual-profile pairing is not enrollment.
    static func rememberedCarDevice(
        _ route: CarBluetoothRouteDescriptor,
        context: CarBluetoothRouteContext = .empty
    ) -> CarBluetoothRouteDescriptor {
        guard isCar(route, context: context) else { return route }
        if route.enrolledAsVehicle { return route }
        return CarBluetoothRouteDescriptor(
            uid: route.uid,
            name: route.name,
            portType: route.portType,
            enrolledAsVehicle: true
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

            if isPlaying, let car = currentCars.first {
                return .schedule(
                    CarBluetoothResumeIntent(
                        device: rememberedCarDevice(car, context: context),
                        episodeID: currentEpisodeID,
                        armedAt: validIntent?.armedAt ?? now
                    )
                )
            }

            if let validIntent {
                let matched = currentCars.first(where: { $0.matches(validIntent.device) })
                    ?? matchingArmedIdentity(routes: currentRoutes, intent: validIntent)
                if let matched {
                    let device = rememberedCarDevice(matched, context: context)
                    return .schedule(
                        CarBluetoothResumeIntent(
                            device: device.kind == .car || isCar(device, context: context)
                                ? device
                                : validIntent.device,
                            episodeID: validIntent.episodeID ?? currentEpisodeID,
                            armedAt: validIntent.armedAt
                        )
                    )
                }
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
        // Model 3 keeps HFP-only until the phone plays. Commit when the armed
        // identity is back, including HFP. Unknown HFP accessories do not match.
        return matchingArmedIdentity(routes: currentRoutes, intent: scheduled) != nil
            || hasMatchingCar(matching: scheduled.device, in: currentRoutes, context: context)
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
        return matchingArmedIdentity(routes: currentRoutes, intent: intent) != nil
            || hasMatchingCar(matching: intent.device, in: currentRoutes, context: context)
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
        return matchingArmedIdentity(routes: routes, intent: intent) != nil
            || hasMatchingCar(matching: intent.device, in: routes, context: context)
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

    static func currentAudioSessionRoutes(
        session: AVAudioSession = .sharedInstance()
    ) -> [CarBluetoothRouteDescriptor] {
        session.currentRoute.outputs.map { CarBluetoothRouteDescriptor($0) }
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

/// One-time, user-explicit enrollment of a Bluetooth output as the car.
/// Headphones are never enrollable. Dual-profile pairing is not enrollment.
enum CarBluetoothEnrollment {
    static func enrollableDevice(
        in routes: [CarBluetoothRouteDescriptor]
    ) -> CarBluetoothRouteDescriptor? {
        let candidates = routes.filter { route in
            guard CarBluetoothPlaybackPolicy.isBluetoothPort(route.portType) else { return false }
            let kind = CarBluetoothPlaybackPolicy.deviceKind(
                portType: route.portType,
                name: route.name
            )
            return kind != .headphone && kind != .notBluetooth
        }
        if let preferred = candidates.first(where: {
            $0.portType == .bluetoothA2DP || $0.portType == .carAudio
        }) {
            return preferred
        }
        return candidates.first
    }

    /// Replaces any previous enrollment with the connected enrollable device.
    /// Personal app: one remembered car.
    static func enroll(routes: [CarBluetoothRouteDescriptor]) -> [String]? {
        guard let device = enrollableDevice(in: routes) else { return nil }
        return [device.stableDeviceKey]
    }

    /// Forgets the remembered car. Safe when nothing is enrolled.
    static func unenroll() -> [String] {
        []
    }

    static func snapshot(
        routes: [CarBluetoothRouteDescriptor],
        enrolledKeys: [String]
    ) -> CarBluetoothSettingsPayload {
        let device = enrollableDevice(in: routes)
        let key = device?.stableDeviceKey
        let currentEnrolled = key.map { enrolledKeys.contains($0) } ?? false
        return CarBluetoothSettingsPayload(
            enrolled: !enrolledKeys.isEmpty,
            enrollable: device != nil,
            current_enrolled: currentEnrolled,
            current_device_name: device?.name,
            current_device_key: key
        )
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
