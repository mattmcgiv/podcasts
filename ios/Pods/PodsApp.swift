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
    private var localServer: PodsLocalServer?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PodsDebugLog("App launch bundle=\(Bundle.main.bundleIdentifier ?? "unknown") version=\(Self.bundleVersionSummary())")
        AudioBridge.shared.configureSession()
        do {
            let databaseURL = try DatabaseBootstrap.prepare()
            PodsDebugLog("Database prepared at \(databaseURL.path)")
            let database = try PodsDatabase(url: databaseURL)
            PodsDebugLog("Database summary \(Self.databaseSummary(database))")
            let backend = PodsBackend(database: database)
            AudioBridge.shared.progressRecorder = backend
            let server = PodsLocalServer(backend: backend)
            try server.start()
            localServer = server
            PodsDebugLog("Local backend start requested")
        } catch {
            PodsLog("Pods local backend startup failed: \(error)")
        }
        return true
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
