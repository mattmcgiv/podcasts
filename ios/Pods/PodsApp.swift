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
    private var localServer: PodsLocalServer?
    private var refreshCoordinator: FeedRefreshCoordinator?
    private var adRemovalDiagnostics: AdRemovalDiagnostics?
    private var adRemovalDownloader: AdRemovalBackgroundDownloader?
    private var adRemovalCoordinator: AdRemovalCoordinator?
    private var pendingAdRemovalBackgroundEvents: [(String, () -> Void)] = []

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerBackgroundRefreshTask()
        adRemovalDiagnostics = try? AdRemovalDiagnostics.applicationDefault(component: .iphone)
        try? adRemovalDiagnostics?.record(
            eventName: "application_launch",
            severity: .notice,
            fields: ["launch_options_present": launchOptions == nil ? "false" : "true"]
        )
        PodsDebugLog("App launch bundle=\(Bundle.main.bundleIdentifier ?? "unknown") version=\(Self.bundleVersionSummary())")
        AudioBridge.shared.diagnostics = adRemovalDiagnostics
        AudioBridge.shared.configureSession()
        do {
            let databaseURL = try DatabaseBootstrap.prepare()
            PodsDebugLog("Database prepared at \(databaseURL.path)")
            let database = try PodsDatabase(url: databaseURL)
            PodsDebugLog("Database summary \(Self.databaseSummary(database))")
            let artifactStore = try AdRemovalArtifactStore.applicationDefault()
            let cleanup = AdRemovalFileCleanup(
                database: database,
                artifactStore: artifactStore,
                diagnostics: adRemovalDiagnostics
            )
            _ = try cleanup.drain()
            let jobStore = AdRemovalJobStore(database: database)
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
                transcriber: AppleSpeechAnalyzerTranscriber(diagnostics: adRemovalDiagnostics)
            )
            adRemovalDownloader = downloader
            adRemovalCoordinator = AdRemovalCoordinator(
                store: jobStore,
                executor: pipeline,
                diagnostics: adRemovalDiagnostics
            )
            for (identifier, completion) in pendingAdRemovalBackgroundEvents {
                if !downloader.handleBackgroundEvents(
                    identifier: identifier,
                    completionHandler: completion
                ) {
                    completion()
                }
            }
            pendingAdRemovalBackgroundEvents.removeAll()
            let backend = PodsBackend(
                database: database,
                adRemovalArtifactStore: artifactStore
            )
            let coordinator = FeedRefreshCoordinator(backend: backend)
            backend.setRefreshRequestHandler { source in
                await coordinator.refreshNow(source: source)
            }
            AudioBridge.shared.progressRecorder = backend
            let server = PodsLocalServer(backend: backend)
            try server.start()
            localServer = server
            refreshCoordinator = coordinator
            scheduleBackgroundRefresh()
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
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleBackgroundRefresh()
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if let adRemovalDownloader {
            if !adRemovalDownloader.handleBackgroundEvents(
                identifier: identifier,
                completionHandler: completionHandler
            ) {
                completionHandler()
            }
        } else {
            pendingAdRemovalBackgroundEvents.append((identifier, completionHandler))
        }
    }

    private func registerBackgroundRefreshTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskIdentifier, using: nil) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handleBackgroundRefresh(refreshTask)
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
