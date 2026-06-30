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
        AudioBridge.shared.configureSession()
        do {
            let databaseURL = try DatabaseBootstrap.prepare()
            let database = try PodsDatabase(url: databaseURL)
            let backend = PodsBackend(database: database)
            let server = PodsLocalServer(backend: backend)
            try server.start()
            localServer = server
        } catch {
            PodsLog("Pods local backend startup failed: \(error)")
        }
        return true
    }
}
