import BackgroundTasks
import SwiftUI
import UIKit

private enum PodsAppRuntimeError: LocalizedError {
    case localServerUnavailable(String?)
    case staticAssetsUnavailable

    var errorDescription: String? {
        switch self {
        case .localServerUnavailable(let detail):
            return detail.map { "Pods local server is unavailable: \($0)" }
                ?? "Pods local server is unavailable"
        case .staticAssetsUnavailable:
            return "Pods packaged UI assets are unavailable"
        }
    }
}

@main
struct PodsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            PodsWebView(appDelegate: appDelegate)
                .ignoresSafeArea()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    private static let refreshTaskIdentifier = "dev.mcgiv.pods.feed-refresh"
    private static let adRemovalTaskIdentifier = "dev.mcgiv.pods.ad-removal-processing"
    private var localServer: PodsLocalServer?
    private var refreshCoordinator: FeedRefreshCoordinator?
    private let foregroundRefreshLifecycle = ForegroundFeedRefreshLifecycle()
    private var adRemovalDiagnostics: AdRemovalDiagnostics?
    private var adRemovalDownloader: AdRemovalBackgroundDownloader?
    private var adRemovalModelDownloader: AdModelBackgroundDownloader?
    private var adRemovalAvailabilityObserver: AppleOnDeviceModelAvailabilityObserver?
    private var adRemovalCoordinator: AdRemovalCoordinator?
    private var adRemovalScheduler: AdRemovalPipelineScheduler?
    private var adRemovalRangeServer: AdRemovalRangeServer?
    private var adRemovalWork: Task<Void, Never>?
    private var adRemovalWorkToken: UUID?
    private var adRemovalBackgroundWork: Task<Void, Never>?
    private var adRemovalBackgroundWorkToken: UUID?
    private var adRemovalCancellationDepth = 0
    private var adRemovalEnabled: (() -> Bool)?
    private var pendingAdRemovalBackgroundEvents: [(String, () -> Void)] = []
    private var startupFailureDescription: String?
    private var startupDatabase: PodsDatabase?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerBackgroundTasks()
        // SwiftUI may deliver the initial active transition before the native
        // backend is ready. Queue it now and consume it after coordinator setup.
        foregroundRefreshLifecycle.applicationDidBecomeActive()
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
            startupDatabase = database
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
            let episodeShowNotesService = EpisodeShowNotesService(
                database: database,
                generator: AppleFoundationEpisodeShowNotesGenerator(
                    diagnostics: adRemovalDiagnostics
                )
            )
            let diagnostics = adRemovalDiagnostics
            try Self.repairAccidentalNextTenYearsSkipUndo(database: database)
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
                classifier: AppleFoundationAdClassifier(
                    diagnostics: adRemovalDiagnostics
                ),
                diagnostics: adRemovalDiagnostics
            )
            adRemovalDownloader = downloader
            let adCoordinator = AdRemovalCoordinator(
                store: jobStore,
                executor: pipeline,
                diagnostics: adRemovalDiagnostics,
                readyHandler: { episodeID in
                    do {
                        _ = try await episodeShowNotesService.generate(episodeID: episodeID)
                    } catch is CancellationError {
                        // Episode or feature cleanup owns cancellation; no retry is appropriate here.
                    } catch {
                        let nsError = error as NSError
                        try? diagnostics?.record(
                            eventName: "episode_show_notes_generation_failed",
                            severity: .warning,
                            context: .init(episodeID: episodeID),
                            fields: [
                                "error_domain": nsError.domain,
                                "error_code": String(nsError.code)
                            ]
                        )
                    }
                }
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
                    return AdRemovalRuntimeConditions(
                        lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                        seriousThermalPressure: thermalState == .serious || thermalState == .critical
                    )
                },
                diagnostics: adRemovalDiagnostics
            )
            adRemovalScheduler = scheduler
            adRemovalEnabled = { Self.isAdRemovalEnabled(database: database) }
            let availabilityReader = SystemLanguageModelAvailabilityReader()
            let availabilityObserver = AppleOnDeviceModelAvailabilityObserver(
                reader: availabilityReader
            ) { [weak self] in
                try? jobStore.clearBlockingReasons([.modelRequired])
                try? diagnostics?.record(
                    eventName: "on_device_model_became_available",
                    severity: .notice
                )
                self?.requestAdRemovalRun()
            }
            adRemovalAvailabilityObserver = availabilityObserver
            if availabilityReader.currentAvailability().available {
                try? jobStore.clearBlockingReasons([.modelRequired])
            }
            availabilityObserver.startPolling()
            let modelDownloader = AdModelBackgroundDownloader(
                database: database,
                assetStore: modelStore,
                diagnostics: adRemovalDiagnostics
            )
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
                adRemovalDiagnostics: adRemovalDiagnostics,
                onDeviceModelAvailability: availabilityReader,
                episodeShowNotesService: episodeShowNotesService
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
            backend.setAdRemovalCancellationRequestHandler { [weak self, weak modelDownloader] scope in
                await self?.cancelAdRemovalWork(scope)
                if scope == .all {
                    await modelDownloader?.cancel()
                }
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
            guard let staticAssets = PodsStaticAssets.bundled() else {
                throw PodsAppRuntimeError.staticAssetsUnavailable
            }
            let server = PodsLocalServer(backend: backend, staticAssets: staticAssets)
            try server.start()
            localServer = server
            refreshCoordinator = coordinator
            installForegroundRefreshHandler(coordinator)
            scheduleBackgroundRefresh()
            Self.approveCrashRecoveryModelReplacement(database: database)
            requestAdRemovalRun()
            PodsDebugLog("Local backend start requested")
        } catch {
            startupFailureDescription = error.localizedDescription
            PodsLog("Pods local backend startup failed: \(error)")
            if let startupDatabase {
                do {
                    try startMinimalCoreServices(database: startupDatabase)
                    startupFailureDescription = nil
                    PodsLog("Pods core UI recovered without optional startup services")
                } catch {
                    startupFailureDescription = error.localizedDescription
                    PodsLog("Pods core UI fallback startup failed: \(error)")
                }
            }
        }
        return true
    }

    /// Used by WebView recovery to restore the loopback dependency before it
    /// attempts another navigation. A positive HTTP probe is part of success.
    @MainActor
    func ensureLocalServerReady() async throws -> Bool {
        if localServer == nil {
            do {
                let database: PodsDatabase
                if let startupDatabase {
                    database = startupDatabase
                } else {
                    let databaseURL = try DatabaseBootstrap.prepare()
                    database = try PodsDatabase(url: databaseURL)
                    startupDatabase = database
                }
                try startMinimalCoreServices(database: database)
                startupFailureDescription = nil
            } catch {
                startupFailureDescription = error.localizedDescription
                throw PodsAppRuntimeError.localServerUnavailable(startupFailureDescription)
            }
        }
        guard let localServer else {
            throw PodsAppRuntimeError.localServerUnavailable(startupFailureDescription)
        }
        return try await localServer.ensureReady()
    }

    private func startMinimalCoreServices(database: PodsDatabase) throws {
        guard localServer == nil else { return }
        guard let staticAssets = PodsStaticAssets.bundled() else {
            throw PodsAppRuntimeError.staticAssetsUnavailable
        }
        let backend = PodsBackend(
            database: database,
            adRemovalDiagnostics: adRemovalDiagnostics
        )
        let coordinator = FeedRefreshCoordinator(backend: backend)
        backend.setRefreshRequestHandler { source in
            await coordinator.refreshNow(source: source)
        }
        AudioBridge.shared.progressRecorder = backend
        let server = PodsLocalServer(backend: backend, staticAssets: staticAssets)
        try server.start()
        localServer = server
        refreshCoordinator = coordinator
        installForegroundRefreshHandler(coordinator)
        scheduleBackgroundRefresh()
        PodsDebugLog("Minimal local backend start requested")
    }

    private static func repairAccidentalNextTenYearsSkipUndo(database: PodsDatabase) throws {
        let marker = "repair_next_ten_years_skip_undo_20260717"
        let alreadyApplied = try database.query(
            "SELECT value FROM settings WHERE key = ?",
            [.text(marker)],
            map: { sqliteString($0, 0) }
        ).first == "done"
        guard !alreadyApplied else { return }

        let correctionID = "36c497a6-37ae-4cfa-a6ef-ff4e3531b630"
        let rangeID = "ad-segment-000143-000621780-000624780--segment-000179-000780120-000784620"
        try database.withTransaction {
            try database.execute(
                "DELETE FROM ad_corrections WHERE id = ? AND source_episode_id = 15242",
                [.text(correctionID)]
            )
            try database.execute(
                "UPDATE ad_skip_ranges SET disabled = 0 WHERE id = ? AND episode_id = 15242",
                [.text(rangeID)]
            )
            try database.execute(
                "INSERT INTO settings (key, value) VALUES (?, 'done') ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [.text(marker)]
            )
        }
        PodsDebugLog("Applied ad-removal state repair \(marker)")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        foregroundRefreshLifecycle.applicationDidBecomeActive()
        adRemovalAvailabilityObserver?.startPolling()
        adRemovalAvailabilityObserver?.poll()
    }

    private func installForegroundRefreshHandler(_ coordinator: FeedRefreshCoordinator) {
        foregroundRefreshLifecycle.install { [weak self, coordinator] in
            let result = await coordinator.refreshWhenForegrounded()
            await MainActor.run {
                self?.scheduleBackgroundRefresh()
                self?.requestAdRemovalRun()
            }
            return result
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        adRemovalAvailabilityObserver?.stopPolling()
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
        guard adRemovalWork == nil,
              adRemovalCancellationDepth == 0,
              adRemovalEnabled?() == true,
              let adRemovalScheduler else { return }
        scheduleAdRemovalProcessing()
        let token = UUID()
        adRemovalWorkToken = token
        adRemovalWork = Task { [weak self, adRemovalScheduler] in
            await adRemovalScheduler.runUntilIdle()
            await MainActor.run {
                guard self?.adRemovalWorkToken == token else { return }
                self?.adRemovalWork = nil
                self?.adRemovalWorkToken = nil
            }
        }
    }

    @MainActor
    private func cancelAdRemovalWork(_ scope: AdRemovalPipelineCancellationScope) async {
        adRemovalCancellationDepth += 1
        defer { adRemovalCancellationDepth -= 1 }
        let foreground = adRemovalWork
        let foregroundToken = adRemovalWorkToken
        let background = adRemovalBackgroundWork
        let backgroundToken = adRemovalBackgroundWorkToken
        foreground?.cancel()
        background?.cancel()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.adRemovalTaskIdentifier)
        await adRemovalCoordinator?.cancel(scope)
        await foreground?.value
        await background?.value
        if adRemovalWorkToken == foregroundToken {
            adRemovalWork = nil
            adRemovalWorkToken = nil
        }
        if adRemovalBackgroundWorkToken == backgroundToken {
            adRemovalBackgroundWork = nil
            adRemovalBackgroundWorkToken = nil
        }
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
        guard adRemovalBackgroundWork == nil, adRemovalCancellationDepth == 0 else {
            task.setTaskCompleted(success: false)
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
        let token = UUID()
        adRemovalBackgroundWorkToken = token
        work = Task { [weak self, adRemovalScheduler] in
            let runResult = await adRemovalScheduler.runUntilIdle()
            // Never report success for a concurrent/busy invocation that did not
            // own pipeline work, or for cancellation / unsuccessful ownership runs.
            let success = !Task.isCancelled && runResult.isSuccessful
            task.setTaskCompleted(success: success)
            try? self?.adRemovalDiagnostics?.record(
                eventName: "background_processing_finished",
                severity: success ? .notice : .warning
            )
            self?.scheduleAdRemovalProcessing()
            await MainActor.run {
                guard self?.adRemovalBackgroundWorkToken == token else { return }
                self?.adRemovalBackgroundWork = nil
                self?.adRemovalBackgroundWorkToken = nil
            }
        }
        adRemovalBackgroundWork = work
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

    /// The previously approved Qwen3.5-4B model deterministically exceeded the
    /// iPhone's process-memory limit. Carry that existing approval forward only
    /// for this pinned crash-recovery replacement; future model revisions still
    /// require the normal explicit size consent flow.
    private static func approveCrashRecoveryModelReplacement(database: PodsDatabase) {
        guard isAdRemovalEnabled(database: database) else { return }
        let priorRevision = try? database.query(
            "SELECT value FROM settings WHERE key = 'ad_removal_model_revision'",
            map: { sqliteString($0, 0) }
        ).first
        guard priorRevision == "32f3e8ecf65426fc3306969496342d504bfa13f3" else { return }
        try? database.execute(
            """
            INSERT INTO settings (key, value) VALUES ('ad_removal_model_download_state', 'consented')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
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
