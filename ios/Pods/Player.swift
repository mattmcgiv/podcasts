import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Native playback of downloaded episodes: background audio, lock-screen and car
/// controls, autoplay of the next episode, and progress that syncs to the Mac.
@MainActor @Observable
final class Player {
    static let shared = Player()

    enum Context: String { case listen, show }
    static let skipForward: Double = 30
    static let skipBack: Double = 15
    static let speeds: [Double] = [1, 1.5, 2, 2.5, 3]

    private(set) var current: Episode?
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var speed: Double = 1
    var expanded = false
    private(set) var playingOnMac = false
    private(set) var speakerBusy = false
    private(set) var speakerError: String?

    @ObservationIgnored private let speaker = MacSpeaker()
    @ObservationIgnored private var speakerGeneration: UInt64?
    @ObservationIgnored private var speakerPoll: Task<Void, Never>?
    @ObservationIgnored private var speakerRevision = 0

    @ObservationIgnored let avPlayer = AVPlayer()
    @ObservationIgnored private var context: Context = .listen
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var savesSinceSync = 0
    @ObservationIgnored private var artwork: (url: URL, image: MPMediaItemArtwork)?
    @ObservationIgnored private var wantsPlay = false
    @ObservationIgnored let car = CarResume()

    private var library: Library { .shared }
    private var downloads: Downloads { .shared }

    init() {
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        avPlayer.allowsExternalPlayback = false
        configureSession()
        registerRemoteCommands()
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        statusObserver = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, !self.playingOnMac, !self.speakerBusy else { return }
                self.playingChanged(self.avPlayer.timeControlStatus != .paused)
            }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated { self?.interrupted(type, options) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            MainActor.assumeIsolated { self?.routeChanged(reason, previous) }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition(sync: true) }
        }
    }

    // MARK: Loading

    /// Show the last-listened episode paused, so Play on the lock screen or in the car resumes it.
    func restore() {
        guard current == nil, let id = library.lastListened, let episode = library.episode(id),
              episode.isUnplayed, downloads.isDownloaded(episode) else { return }
        load(episode, context: .listen, autoplay: false)
    }

    func play(_ episode: Episode, context: Context) {
        guard !speakerBusy else { return }
        if current?.id == episode.id { expanded = true; if !isPlaying { resume() }; return }
        guard downloads.isDownloaded(episode) else { downloads.request(episode); return }
        if let generation = speakerGeneration {
            onSpeaker {
                self.expanded = true
                try await self.changeMacEpisode(episode, context: context, generation: generation)
            }
            return
        }
        speakerError = nil
        savePosition(sync: false)
        if let current { library.endPlayback(current) }
        load(episode, context: context, autoplay: true)
        expanded = true
    }

    private func load(_ episode: Episode, context: Context, autoplay: Bool) {
        guard let url = downloads.fileURL(for: episode) else { return }
        self.context = context
        current = episode
        downloads.protectedHash = episode.manifest?.hash
        position = episode.position_secs > 1 ? episode.position_secs : 0
        duration = episode.duration
        speed = library.speed
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended() }
        }
        avPlayer.replaceCurrentItem(with: item)
        avPlayer.defaultRate = Float(speed)
        if position > 0 { avPlayer.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        if autoplay {
            library.beginPlayback(episode)
            resume()
        } else {
            wantsPlay = false
            publishNowPlaying()
        }
        loadArtwork(for: episode)
        DeviceLog.write("load episode=\(episode.id) at=\(Int(position)) autoplay=\(autoplay)")
    }

    func close(then completion: @escaping () -> Void) {
        guard !speakerBusy else { return }
        if playingOnMac {
            onSpeaker {
                _ = try await self.stopMac()
                self.savePosition(sync: true)
                self.clearCurrent()
                completion()
            }
        } else {
            savePosition(sync: true)
            clearCurrent()
            completion()
        }
    }

    private func clearCurrent() {
        if let current { library.endPlayback(current) }
        clearMacOutput()
        isPlaying = false
        wantsPlay = false
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        current = nil
        expanded = false
        downloads.protectedHash = nil
        car.disarm()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Transport

    func resume() {
        guard !speakerBusy else { return }
        if playingOnMac { sendSpeaker(.play); return }
        resumeOnPhone()
    }

    private func resumeOnPhone() {
        guard current != nil else { restore(); if current != nil { resume() }; return }
        wantsPlay = true
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { DeviceLog.write("audio session activate failed: \(error.localizedDescription)") }
        avPlayer.defaultRate = Float(speed)
        avPlayer.play()
        publishNowPlaying()
    }

    func pause() {
        guard !speakerBusy else { return }
        if playingOnMac { sendSpeaker(.pause); return }
        wantsPlay = false
        car.disarm()
        avPlayer.pause()
        savePosition(sync: true)
        publishNowPlaying()
    }

    func toggle() { isPlaying ? pause() : resume() }

    func seek(to seconds: Double) {
        guard current != nil, !speakerBusy else { return }
        let target = max(0, duration > 0 ? min(seconds, max(0, duration - 0.5)) : seconds)
        if playingOnMac { sendSpeaker(.seek, value: target); return }
        position = target
        let item = avPlayer.currentItem
        avPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard finished, let self, !self.playingOnMac, self.avPlayer.currentItem === item else { return }
                self.publishNowPlaying()
                self.savePosition(sync: true)
            }
        }
    }

    func skip(_ delta: Double) { seek(to: position + delta) }

    func setSpeed(_ value: Double) {
        guard !speakerBusy else { return }
        if playingOnMac { sendSpeaker(.rate, value: value); return }
        speed = value
        avPlayer.defaultRate = Float(value)
        if isPlaying { avPlayer.rate = Float(value) }
        library.setSetting("speed", .number(value))
        publishNowPlaying()
    }

    func markCurrentPlayed() {
        guard let episode = current, !speakerBusy else { return }
        close {
            self.library.setPlayed(episode, true)
            self.downloads.run()
        }
    }

    // MARK: Mac speaker

    func switchOutput() {
        guard let episode = current, !library.readOnly, !speakerBusy else { return }
        if playingOnMac {
            onSpeaker {
                do {
                    let shouldResume = try await self.stopMac()
                    self.returnToPhone(autoplay: shouldResume)
                } catch {
                    self.returnToPhone(autoplay: false)
                    throw SyncError.message("Could not confirm that the Mac stopped. Playback is paused on this iPhone.")
                }
            }
        } else {
            onSpeaker {
                let status = try await self.speaker.status()
                guard status.available else { throw SyncError.message(status.error ?? "Mac speaker is unavailable.") }
                let shouldResume = self.wantsPlay
                self.car.disarm()
                self.wantsPlay = false
                self.avPlayer.pause()
                self.isPlaying = false
                let localTime = self.avPlayer.currentTime().seconds
                if localTime.isFinite, localTime >= 0 { self.position = localTime }
                do {
                    let loaded = try await self.speaker.load(episode, generation: status.generation,
                                                             position: self.position, rate: self.speed)
                    try self.adoptMac(loaded, episode: episode)
                } catch {
                    if shouldResume { self.resumeOnPhone() }
                    throw error
                }
                if shouldResume { try await self.updateSpeaker(.play) }
            }
        }
    }

    private func onSpeaker(_ action: @escaping @MainActor () async throws -> Void) {
        guard !speakerBusy else { return }
        speakerBusy = true
        speakerError = nil
        speakerRevision += 1
        Task {
            defer {
                speakerBusy = false
                if !playingOnMac { playingChanged(avPlayer.timeControlStatus != .paused) }
            }
            do { try await action() }
            catch { speakerError = error.localizedDescription }
        }
    }

    private func adoptMac(_ status: MacSpeaker.Status, episode: Episode) throws {
        guard speaker.owns(status, episode: episode) else {
            throw SyncError.message(status.error ?? "The Mac speaker did not load this episode.")
        }
        speakerGeneration = status.generation
        playingOnMac = true
        applySpeakerStatus(status)
        startSpeakerPolling()
    }

    private func applySpeakerStatus(_ status: MacSpeaker.Status) {
        position = status.position
        if status.duration > 0 { duration = status.duration }
        speed = status.rate
        isPlaying = !status.paused && !status.ended
        publishNowPlaying()
    }

    private func sendSpeaker(_ command: MacSpeaker.Command, value: Double? = nil) {
        onSpeaker { try await self.updateSpeaker(command, value: value) }
    }

    private func updateSpeaker(_ command: MacSpeaker.Command, value: Double? = nil) async throws {
        guard let generation = speakerGeneration, let episode = current else { return }
        let status = try await speaker.command(command, generation: generation, value: value)
        guard speaker.owns(status, episode: episode), status.generation == generation else {
            throw SyncError.message("The Mac speaker has switched to another session.")
        }
        applySpeakerStatus(status)
        if command == .rate { library.setSetting("speed", .number(speed)) }
        if command == .pause || command == .seek { savePosition(sync: true) }
    }

    private func stopMac() async throws -> Bool {
        guard let episode = current, let generation = speakerGeneration else { return false }
        let status = try await speaker.status()
        guard speaker.owns(status, episode: episode), status.generation == generation else { return false }
        applySpeakerStatus(status)
        let stopped = try await speaker.command(.disconnect, generation: generation)
        position = stopped.position
        return !status.paused && !status.ended
    }

    private func clearMacOutput() {
        speakerGeneration = nil
        speakerPoll?.cancel()
        speakerPoll = nil
        playingOnMac = false
    }

    private func returnToPhone(autoplay: Bool) {
        savePosition(sync: true)
        clearMacOutput()
        isPlaying = false
        avPlayer.defaultRate = Float(speed)
        avPlayer.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if autoplay { resumeOnPhone() }
        else { publishNowPlaying() }
    }

    private func changeMacEpisode(_ episode: Episode, context: Context, generation: UInt64,
                                  finished: Episode? = nil) async throws {
        let loaded = try await speaker.load(episode, generation: generation,
                                            position: episode.position_secs > 1 ? episode.position_secs : 0, rate: speed)
        guard speaker.owns(loaded, episode: episode) else {
            throw SyncError.message(loaded.error ?? "The Mac speaker did not load this episode.")
        }
        savePosition(sync: false)
        if let current { library.endPlayback(current) }
        if let finished { library.setPlayed(finished, true) }
        load(episode, context: context, autoplay: false)
        library.beginPlayback(episode)
        try adoptMac(loaded, episode: episode)
        try await updateSpeaker(.play)
    }

    private func startSpeakerPolling() {
        guard speakerPoll == nil else { return }
        speakerPoll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                await self?.pollSpeaker()
            }
        }
    }

    private func pollSpeaker() async {
        guard !speakerBusy, let generation = speakerGeneration, let episode = current else { return }
        let revision = speakerRevision
        do {
            let status = try await speaker.status()
            guard revision == speakerRevision, speakerGeneration == generation else { return }
            guard speaker.owns(status, episode: episode), status.generation == generation else {
                returnToPhone(autoplay: false)
                speakerError = status.error ?? "The Mac speaker session ended. Playback is paused on this iPhone."
                return
            }
            if speakerError == "Could not reach the Mac speaker." { speakerError = nil }
            applySpeakerStatus(status)
            if status.ended {
                finishOnMac(episode, generation: generation)
            } else if isPlaying, Date().timeIntervalSince(lastSave) >= 5 {
                savesSinceSync += 1
                savePosition(sync: savesSinceSync >= 6)
            }
        } catch {
            guard revision == speakerRevision, speakerGeneration == generation else { return }
            speakerError = "Could not reach the Mac speaker."
        }
    }

    private func finishOnMac(_ episode: Episode, generation: UInt64) {
        let next = library.autoplay
            ? SyncLogic.next(after: episode, in: library.episodes, sameShowOnly: context == .show, isDownloaded: downloads.isDownloaded)
            : nil
        onSpeaker {
            defer { self.downloads.run() }
            do {
                if let next {
                    try await self.changeMacEpisode(next, context: self.context, generation: generation, finished: episode)
                } else {
                    _ = try await self.stopMac()
                    self.savePosition(sync: true)
                    self.clearCurrent()
                    self.library.setPlayed(episode, true)
                }
            } catch {
                // The last confirmed status was ended. Any replacement was loaded paused.
                if self.current?.id == episode.id {
                    self.returnToPhone(autoplay: false)
                    self.library.endPlayback(episode)
                    self.library.setPlayed(episode, true)
                }
                throw error
            }
        }
    }

    // MARK: Events

    private func tick(_ seconds: Double) {
        guard !playingOnMac, !speakerBusy, current != nil, seconds.isFinite else { return }
        position = seconds
        if let item = avPlayer.currentItem, item.duration.seconds.isFinite, item.duration.seconds > 0 { duration = item.duration.seconds }
        if isPlaying, Date().timeIntervalSince(lastSave) >= 5 {
            savesSinceSync += 1
            savePosition(sync: savesSinceSync >= 6)
        }
    }

    private func playingChanged(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        publishNowPlaying()
    }

    private func savePosition(sync: Bool) {
        guard let current, avPlayer.currentItem != nil else { return }
        let seconds = playingOnMac ? position : avPlayer.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        lastSave = Date()
        if sync { savesSinceSync = 0 }
        library.setPosition(current, seconds: seconds, sync: sync)
    }

    private func ended() {
        guard !playingOnMac, !speakerBusy, let finished = current else { return }
        DeviceLog.write("ended episode=\(finished.id) autoplay=\(library.autoplay)")
        let next = library.autoplay
            ? SyncLogic.next(after: finished, in: library.episodes, sameShowOnly: context == .show, isDownloaded: downloads.isDownloaded)
            : nil
        library.endPlayback(finished)
        library.setPlayed(finished, true)
        if let next {
            let keepExpanded = expanded
            load(next, context: context, autoplay: true)
            expanded = keepExpanded
        } else {
            wantsPlay = false
            avPlayer.replaceCurrentItem(with: nil)
            current = nil
            expanded = false
            downloads.protectedHash = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        downloads.run()
    }

    private func interrupted(_ type: AVAudioSession.InterruptionType?, _ options: AVAudioSession.InterruptionOptions) {
        guard !playingOnMac, !speakerBusy else { return }
        switch type {
        case .began:
            savePosition(sync: true)
        case .ended:
            if wantsPlay, options.contains(.shouldResume) { resume() }
        default: break
        }
    }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?, _ previous: AVAudioSessionRouteDescription?) {
        guard !playingOnMac, !speakerBusy else { return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        DeviceLog.write("route reason=\(reason?.rawValue ?? 99) outputs=\(outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ","))")
        if reason == .oldDeviceUnavailable {
            // iOS pauses when headphones or the car go away. Remember a car so it can resume.
            let wasPlaying = wantsPlay
            wantsPlay = false
            if wasPlaying, let current, let lost = previous?.outputs { car.arm(lost: lost, episode: current.id) }
            savePosition(sync: true)
            publishNowPlaying()
        } else if reason == .newDeviceAvailable, let current, !isPlaying, car.shouldResume(on: outputs, episode: current.id) {
            DeviceLog.write("car returned; resuming episode=\(current.id)")
            car.disarm()
            // Give the car a moment to finish switching to media audio.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if self.current?.id == current.id, !self.isPlaying { self.resume() }
            }
        }
    }

    // MARK: System integration

    private func configureSession() {
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio) }
        catch { DeviceLog.write("audio session category failed: \(error.localizedDescription)") }
    }

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        let run: (@escaping @MainActor (Player) -> Void) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { action in
            { _ in
                Task { @MainActor in action(Player.shared) }
                return .success
            }
        }
        center.playCommand.addTarget(handler: run { $0.resume() })
        center.pauseCommand.addTarget(handler: run { $0.pause() })
        center.togglePlayPauseCommand.addTarget(handler: run { $0.toggle() })
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForward)]
        center.skipForwardCommand.addTarget(handler: run { $0.skip(Self.skipForward) })
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBack)]
        center.skipBackwardCommand.addTarget(handler: run { $0.skip(-Self.skipBack) })
        // Car steering-wheel and headset buttons only send next/previous: use them to skip within the episode.
        center.nextTrackCommand.addTarget(handler: run { $0.skip(Self.skipForward) })
        center.previousTrackCommand.addTarget(handler: run { $0.skip(-Self.skipBack) })
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = event.positionTime
            Task { @MainActor in self.seek(to: target) }
            return .success
        }
    }

    private func publishNowPlaying() {
        guard let current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.podcast_title,
            MPMediaItemPropertyAlbumTitle: current.podcast_title,
            MPMediaItemPropertyMediaType: MPMediaType.podcast.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork, artwork.url == current.artworkURL { info[MPMediaItemPropertyArtwork] = artwork.image }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for episode: Episode) {
        guard let url = episode.artworkURL, artwork?.url != url else { return }
        Task {
            guard let image = await ArtworkCache.shared.image(for: url) else { return }
            self.artwork = (url, MPMediaItemArtwork(boundsSize: image.size) { _ in image })
            if self.current?.id == episode.id { self.publishNowPlaying() }
        }
    }
}

/// Remembers that playback stopped because a car's Bluetooth went away, so the
/// same car coming back can resume the same episode. Headphones never arm it.
@MainActor
final class CarResume {
    private struct Intent: Codable { var device: String; var episode: Int; var armedAt: Date }
    private static let key = "carResumeIntent"
    private static let knownKey = "knownCarDevices"
    /// A stop for fuel or an errand resumes; the next morning does not.
    static let lifetime: TimeInterval = 4 * 60 * 60

    private var intent: Intent? {
        get { UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Intent.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.key) }
    }

    /// Bluetooth outputs the user marked as their car in Settings (cars often have custom names).
    var knownDevices: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.knownKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.knownKey) }
    }

    /// Bluetooth UIDs look like "AA:BB:CC:DD:EE:FF-tacl"; the profile suffix differs between calls and media.
    static func deviceKey(_ port: AVAudioSessionPortDescription) -> String {
        port.uid.split(separator: "-").first.map(String.init) ?? port.uid
    }

    static func isBluetooth(_ port: AVAudioSessionPortDescription) -> Bool {
        [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains(port.portType)
    }

    func isCar(_ port: AVAudioSessionPortDescription) -> Bool {
        if port.portType == .carAudio { return true }
        guard Self.isBluetooth(port) else { return false }
        if knownDevices.contains(Self.deviceKey(port)) { return true }
        return Self.looksLikeCar(port.portName)
    }

    /// Without enrollment only an unmistakable vehicle name counts; headphones must never auto-resume.
    nonisolated static func looksLikeCar(_ portName: String) -> Bool {
        let name = portName.lowercased()
        if ["airpods", "beats", "buds", "headphone", "headset", "speaker"].contains(where: name.contains) { return false }
        return ["tesla", "model 3", "model y", "model s", "model x", "carplay", "car audio", "car stereo", "vehicle"].contains(where: name.contains)
    }

    func arm(lost: [AVAudioSessionPortDescription], episode: Int) {
        guard let car = lost.first(where: isCar) else { return }
        intent = Intent(device: Self.deviceKey(car), episode: episode, armedAt: Date())
        DeviceLog.write("car resume armed device=\(car.portName) episode=\(episode)")
    }

    func disarm() { intent = nil }

    func shouldResume(on outputs: [AVAudioSessionPortDescription], episode: Int) -> Bool {
        guard let intent, intent.episode == episode, Date().timeIntervalSince(intent.armedAt) < Self.lifetime else { return false }
        return outputs.contains { Self.isBluetooth($0) || $0.portType == .carAudio ? Self.deviceKey($0) == intent.device : false }
    }

    /// The Bluetooth output in use right now, for the "This is my car" setting.
    func currentBluetoothOutput() -> AVAudioSessionPortDescription? {
        AVAudioSession.sharedInstance().currentRoute.outputs.first(where: Self.isBluetooth)
    }
}

/// Small in-memory and URL-cache backed artwork loader.
actor ArtworkCache {
    static let shared = ArtworkCache()
    private let memory = NSCache<NSURL, UIImage>()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 200 << 20)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    func image(for url: URL) async -> UIImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }
        guard let (data, _) = try? await session.data(from: url), let image = UIImage(data: data) else { return nil }
        let scale = min(1, 600 / max(image.size.width, image.size.height, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let prepared = await image.byPreparingThumbnail(ofSize: size) ?? image
        memory.setObject(prepared, forKey: url as NSURL)
        return prepared
    }
}
