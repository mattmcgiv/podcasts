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
    private var localServer: PodsLocalServer?
    private var rustBackend: RustBackend?
    private var refreshCoordinator: LoopbackRefreshCoordinator?
    private let foregroundRefreshLifecycle = ForegroundFeedRefreshLifecycle()
    private var startupFailureDescription: String?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerBackgroundTasks()
        foregroundRefreshLifecycle.applicationDidBecomeActive()
        PodsDebugLog("App launch bundle=\(Bundle.main.bundleIdentifier ?? "unknown")")
        AudioBridge.shared.configureSession()
        do {
            try startRustBackend()
            PodsDebugLog("Local rust backend start requested")
        } catch {
            startupFailureDescription = error.localizedDescription
            PodsLog("Pods local backend startup failed: \(error)")
        }
        return true
    }

    @MainActor
    func ensureLocalServerReady() async throws -> Bool {
        if localServer == nil {
            do {
                try startRustBackend()
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

    private func startRustBackend() throws {
        guard localServer == nil else { return }
        guard let staticAssets = PodsStaticAssets.bundled() else {
            throw PodsAppRuntimeError.staticAssetsUnavailable
        }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Pods", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let liveURL = support.appendingPathComponent("pods.sqlite")
        let seedURL = Bundle.main.url(forResource: "pods-seed", withExtension: "sqlite", subdirectory: "SeedData")
        try RustBackend.prepare(liveURL: liveURL, seedURL: seedURL)
        let backend = try RustBackend(databasePath: liveURL.path)
        rustBackend = backend
        AudioBridge.shared.progressRecorder = backend
        let server = PodsLocalServer(backend: backend, staticAssets: staticAssets)
        try server.start()
        localServer = server
        let coordinator = LoopbackRefreshCoordinator()
        refreshCoordinator = coordinator
        installForegroundRefreshHandler(coordinator)
        scheduleBackgroundRefresh()
    }

    private func installForegroundRefreshHandler(_ coordinator: LoopbackRefreshCoordinator) {
        foregroundRefreshLifecycle.install {
            await coordinator.refreshWhenForegrounded()
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleBackgroundRefresh()
    }

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskIdentifier, using: nil) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handleBackgroundRefresh(refreshTask)
        }
    }

    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        guard let refreshCoordinator else {
            task.setTaskCompleted(success: false)
            return
        }
        Task {
            let result = await refreshCoordinator.refreshNow(source: "background")
            task.setTaskCompleted(success: result.errors == 0)
            self.scheduleBackgroundRefresh()
        }
    }
}
