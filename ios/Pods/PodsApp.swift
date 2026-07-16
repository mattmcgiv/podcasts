import BackgroundTasks
import SwiftUI
import UIKit

@main
struct PodsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            PodsWebView()
                .ignoresSafeArea()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    private static let refreshTaskIdentifier = "dev.mcgiv.pods.feed-refresh"
    private static let adRemovalTaskIdentifier = "dev.mcgiv.pods.ad-removal-processing"
    private var localServer: PodsLocalServer?
    private var refreshCoordinator: FeedRefreshCoordinator?
    private var adRemovalDiagnostics: AdRemovalDiagnostics?
    private var adRemovalDownloader: AdRemovalBackgroundDownloader?
    private var adRemovalModelDownloader: AdModelBackgroundDownloader?
    private var adRemovalCoordinator: AdRemovalCoordinator?
    private var adRemovalScheduler: AdRemovalPipelineScheduler?
    private var adRemovalRangeServer: AdRemovalRangeServer?
    private var adRemovalWork: Task<Void, Never>?
    private var adRemovalEnabled: (() -> Bool)?
    private var pendingAdRemovalBackgroundEvents: [(String, () -> Void)] = []

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerBackgroundTasks()
        adRemovalDiagnostics = try? AdRemovalDiagnostics.applicationDefault(component: .iphone)
        try? adRemovalDiagnostics?.record(
            eventName: "application_launch",
            severity: .notice,
            fields: ["launch_options_present": launchOptions == nil ? "false" : "true"]
        )
        PodsDebugLog("App launch bundle=\(Bundle.main.bundleIdentifier ?? "unknown") version=\(Self.bundleVersionSummary())")
        AudioBridge.shared.diagnostics = adRemovalDiagnostics
        let rangeServer = AdRemovalRangeServer(diagnostics: adRemovalDiagnostics)
        rangeServer.start()
        adRemovalRangeServer = rangeServer
        AudioBridge.shared.adRemovalRangeServer = rangeServer
        AudioBridge.shared.configureSession()
        do {
            let databaseURL = try DatabaseBootstrap.prepare()
            PodsDebugLog("Database prepared at \(databaseURL.path)")
            let database = try PodsDatabase(url: databaseURL)
            PodsDebugLog("Database summary \(Self.databaseSummary(database))")
            let artifactStore = try AdRemovalArtifactStore.applicationDefault()
            let modelStore = try AdModelAssetStore(artifactStore: artifactStore)
            let cleanup = AdRemovalFileCleanup(
                database: database,
                artifactStore: artifactStore,
                diagnostics: adRemovalDiagnostics
            )
            _ = try cleanup.drain()
            let jobStore = AdRemovalJobStore(database: database)
            AudioBridge.shared.adRemovalPlaybackProvider = AdRemovalPlaybackStore(
                database: database,
                jobStore: jobStore,
                artifactStore: artifactStore
            )
            let storagePolicy = AdRemovalStoragePolicy(
                usedBytes: { try artifactStore.episodeArtifactBytes() },
                availableBytes: { try artifactStore.availableCapacity() }
            )
            let downloader = AdRemovalBackgroundDownloader(
                jobStore: jobStore,
                artifactStore: artifactStore,
                storagePolicy: storagePolicy,
                diagnostics: adRemovalDiagnostics
            )
            let pipeline = AdRemovalPipelineExecutor(
                database: database,
                jobStore: jobStore,
                artifactStore: artifactStore,
                audioDownloader: downloader,
                transcriber: AppleSpeechAnalyzerTranscriber(diagnostics: adRemovalDiagnostics),
                classifier: MLXQwenAdClassifier(
                    assetStore: modelStore,
                    diagnostics: adRemovalDiagnostics
                ),
                diagnostics: adRemovalDiagnostics
            )
            adRemovalDownloader = downloader
            let adCoordinator = AdRemovalCoordinator(
                store: jobStore,
                executor: pipeline,
                diagnostics: adRemovalDiagnostics
            )
            adRemovalCoordinator = adCoordinator
            let scheduler = AdRemovalPipelineScheduler(
                store: jobStore,
                coordinator: adCoordinator,
                isEnabled: {
                    Self.isAdRemovalEnabled(database: database)
                },
                conditions: {
                    let thermalState = ProcessInfo.processInfo.thermalState
                    let playbackActive = await MainActor.run {
                        AudioBridge.shared.isEpisodePlaybackActive
                    }
                    return AdRemovalRuntimeConditions(
                        lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                        seriousThermalPressure: thermalState == .serious || thermalState == .critical,
                        playbackActive: playbackActive
                    )
                },
                diagnostics: adRemovalDiagnostics
            )
            adRemovalScheduler = scheduler
            adRemovalEnabled = { Self.isAdRemovalEnabled(database: database) }
            let modelDownloader = AdModelBackgroundDownloader(
                database: database,
                assetStore: modelStore,
                diagnostics: adRemovalDiagnostics
            )
            modelDownloader.modelReadyHandler = { [weak self] in
                try? jobStore.clearBlockingReasons([.modelRequired])
                self?.requestAdRemovalRun()
            }
            adRemovalModelDownloader = modelDownloader
            for (identifier, completion) in pendingAdRemovalBackgroundEvents {
                if downloader.handleBackgroundEvents(
                    identifier: identifier,
                    completionHandler: completion
                ) {
                    continue
                }
                if modelDownloader.handleBackgroundEvents(
                    identifier: identifier,
                    completionHandler: completion
                ) {
                    continue
                }
                completion()
            }
            pendingAdRemovalBackgroundEvents.removeAll()
            let backend = PodsBackend(
                database: database,
                adRemovalArtifactStore: artifactStore,
                adRemovalDiagnostics: adRemovalDiagnostics
            )
            let coordinator = FeedRefreshCoordinator(backend: backend)
            backend.setRefreshRequestHandler { source in
                await coordinator.refreshNow(source: source)
            }
            backend.setAdRemovalRunRequestHandler { [weak self] in
                await MainActor.run { self?.requestAdRemovalRun() }
            }
            backend.setAdRemovalModelDownloadRequestHandler { [weak modelDownloader] manifest in
                await modelDownloader?.start(requestedManifest: manifest)
            }
            backend.setAdRemovalStopRequestHandler { [weak self, weak modelDownloader] in
                await MainActor.run { self?.cancelAdRemovalWork() }
                await modelDownloader?.cancel()
            }
            AudioBridge.shared.playbackActivityDidChange = { [weak self] active in
                if !active { self?.requestAdRemovalRun() }
            }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(adRemovalConditionsDidChange),
                name: .NSProcessInfoPowerStateDidChange,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(adRemovalConditionsDidChange),
                name: ProcessInfo.thermalStateDidChangeNotification,
                object: nil
            )
            AudioBridge.shared.progressRecorder = backend
            let server = PodsLocalServer(backend: backend)
            try server.start()
            localServer = server
            refreshCoordinator = coordinator
            scheduleBackgroundRefresh()
            if Self.shouldResumeModelDownload(database: database) {
                Task { await modelDownloader.start(requestedManifest: .qwen35FourBitV1) }
            }
            requestAdRemovalRun()
            PodsDebugLog("Local backend start requested")
        } catch {
            PodsLog("Pods local backend startup failed: \(error)")
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        guard let refreshCoordinator else {
            return
        }
        Task { [weak self, refreshCoordinator] in
            _ = await refreshCoordinator.refreshIfDue()
            self?.scheduleBackgroundRefresh()
            self?.requestAdRemovalRun()
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleBackgroundRefresh()
        scheduleAdRemovalProcessing()
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if let adRemovalDownloader, let adRemovalModelDownloader {
            if adRemovalDownloader.handleBackgroundEvents(
                identifier: identifier,
                completionHandler: completionHandler
            ) {
                return
            }
            if adRemovalModelDownloader.handleBackgroundEvents(
                identifier: identifier,
                completionHandler: completionHandler
            ) {
                return
            }
            completionHandler()
        } else {
            pendingAdRemovalBackgroundEvents.append((identifier, completionHandler))
        }
    }

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskIdentifier, using: nil) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handleBackgroundRefresh(refreshTask)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.adRemovalTaskIdentifier, using: nil) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handleAdRemovalProcessing(processingTask)
        }
    }

    private func scheduleBackgroundRefresh() {
        guard let refreshCoordinator else {
            return
        }
        Task { [refreshCoordinator] in
            let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
            request.earliestBeginDate = await refreshCoordinator.nextBackgroundRefreshDate()
            do {
                try BGTaskScheduler.shared.submit(request)
                PodsDebugLog("Pods background feed refresh requested for \(request.earliestBeginDate?.description ?? "now")")
            } catch {
                PodsLog("Pods background feed refresh request failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        guard let refreshCoordinator else {
            task.setTaskCompleted(success: false)
            return
        }

        var work: Task<Void, Never>?
        task.expirationHandler = {
            PodsLog("Pods background feed refresh expired")
            work?.cancel()
        }
        work = Task { [weak self, refreshCoordinator] in
            let result = await refreshCoordinator.refreshNow(source: .background)
            task.setTaskCompleted(success: !Task.isCancelled && result.errors == 0)
            self?.scheduleBackgroundRefresh()
        }
    }

    private func requestAdRemovalRun() {
        guard adRemovalWork == nil, let adRemovalScheduler else { return }
        scheduleAdRemovalProcessing()
        adRemovalWork = Task { [weak self, adRemovalScheduler] in
            await adRemovalScheduler.runUntilIdle()
            await MainActor.run { self?.adRemovalWork = nil }
        }
    }

    private func cancelAdRemovalWork() {
        adRemovalWork?.cancel()
        adRemovalWork = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.adRemovalTaskIdentifier)
    }

    private func scheduleAdRemovalProcessing() {
        guard adRemovalScheduler != nil, adRemovalEnabled?() == true else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.adRemovalTaskIdentifier)
        let request = BGProcessingTaskRequest(identifier: Self.adRemovalTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            try? adRemovalDiagnostics?.record(
                eventName: "background_processing_scheduled",
                severity: .info,
                fields: ["earliest_begin": request.earliestBeginDate?.description ?? "unknown"]
            )
        } catch {
            let nsError = error as NSError
            try? adRemovalDiagnostics?.record(
                eventName: "background_processing_schedule_failed",
                severity: .warning,
                fields: ["error_domain": nsError.domain, "error_code": String(nsError.code)]
            )
        }
    }

    private func handleAdRemovalProcessing(_ task: BGProcessingTask) {
        guard let adRemovalScheduler, adRemovalEnabled?() == true else {
            task.setTaskCompleted(success: true)
            return
        }
        try? adRemovalDiagnostics?.record(eventName: "background_processing_launch", severity: .notice)
        var work: Task<Void, Never>?
        task.expirationHandler = { [weak self] in
            work?.cancel()
            try? self?.adRemovalDiagnostics?.record(
                eventName: "background_processing_expired",
                severity: .warning
            )
        }
        work = Task { [weak self, adRemovalScheduler] in
            await adRemovalScheduler.runUntilIdle()
            let success = !Task.isCancelled
            task.setTaskCompleted(success: success)
            try? self?.adRemovalDiagnostics?.record(
                eventName: "background_processing_finished",
                severity: success ? .notice : .warning
            )
            self?.scheduleAdRemovalProcessing()
        }
    }

    @objc private func adRemovalConditionsDidChange() {
        let process = ProcessInfo.processInfo
        try? adRemovalDiagnostics?.record(
            eventName: "processing_conditions_changed",
            severity: .notice,
            fields: [
                "low_power": process.isLowPowerModeEnabled ? "true" : "false",
                "thermal_state": String(process.thermalState.rawValue),
                "playback_active": AudioBridge.shared.isEpisodePlaybackActive ? "true" : "false"
            ]
        )
        requestAdRemovalRun()
    }

    private static func isAdRemovalEnabled(database: PodsDatabase) -> Bool {
        (try? database.query(
            "SELECT value FROM settings WHERE key = 'ad_removal_enabled'",
            map: { sqliteString($0, 0) }
        ).first) == "true"
    }

    private static func shouldResumeModelDownload(database: PodsDatabase) -> Bool {
        guard isAdRemovalEnabled(database: database) else { return false }
        let state = try? database.query(
            "SELECT value FROM settings WHERE key = 'ad_removal_model_download_state'",
            map: { sqliteString($0, 0) }
        ).first
        return state == "consented" || state == "downloading" || state == "failed"
    }

    private static func bundleVersionSummary() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let shortVersion = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "\(shortVersion) (\(build))"
    }

    private static func databaseSummary(_ database: PodsDatabase) -> String {
        let podcastCount = (try? database.scalarInt64("SELECT COUNT(*) FROM podcasts")) ?? -1
        let episodeCount = (try? database.scalarInt64("SELECT COUNT(*) FROM episodes")) ?? -1
        let recentCount = (try? database.scalarInt64(
            """
            SELECT COUNT(*) FROM episodes e
            LEFT JOIN episode_state s ON s.episode_id = e.id
            WHERE s.played_at IS NULL AND s.archived_at IS NULL
            """
        )) ?? -1
        let playedCount = (try? database.scalarInt64("SELECT COUNT(*) FROM episode_state WHERE played_at IS NOT NULL")) ?? -1
        return "podcasts=\(podcastCount) episodes=\(episodeCount) recent=\(recentCount) played=\(playedCount)"
    }
}
