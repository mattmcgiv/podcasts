import BackgroundTasks
import SwiftUI

@main
struct PodsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(Library.shared)
                .environment(Downloads.shared)
                .environment(Player.shared)
                .task { await AppCoordinator.shared.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { AppCoordinator.shared.becameActive() }
                    if phase == .background { AppCoordinator.shared.enteredBackground() }
                }
        }
        .backgroundTask(.appRefresh(AppCoordinator.refreshIdentifier)) {
            await AppCoordinator.shared.backgroundRefresh()
        }
    }
}

/// iOS relaunches the app in the background to hand over finished downloads.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == Transfers.identifier else { completionHandler(); return }
        // Creating the session reconnects it; its delegate then receives the finished transfers.
        Transfers.shared.handleEvents(completionHandler)
    }
}

/// Ties the pieces together: pair, sync on a timer, on foreground and in background
/// refresh, keep the download queue following the library, and report to the Mac.
@MainActor
final class AppCoordinator {
    static let shared = AppCoordinator()
    static let refreshIdentifier = "dev.mcgiv.pods.refresh"
    /// How often the app sends its status and the tail of its log to the Mac.
    static let reportInterval: TimeInterval = 30 * 60

    private var started = false
    private var timer: Task<Void, Never>?
    private var lastRevision = -1
    private var lastSync = Date()
    private var lastReport: Date?

    #if targetEnvironment(simulator)
    static let isSimulator = true
    #else
    static let isSimulator = false
    #endif

    /// Hosted unit tests load the app but must not sync, play or schedule anything.
    private var testing: Bool { NSClassFromString("XCTestCase") != nil }

    func start() async {
        guard !started, !testing else { return }
        started = true
        DeviceLog.write("launch \(MacClient.userAgent)")
        // Reconnect to transfers that kept running while the app was closed.
        _ = Transfers.shared
        _ = Player.shared
        await Library.shared.adoptDeliveredPairCode()
        Library.shared.synchronize()
        Player.shared.restore()
        scheduleRefresh()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.follow()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        await Reminders.reschedule(ask: true)
    }

    func becameActive() {
        guard started else { return }
        Task {
            await Library.shared.adoptDeliveredPairCode()
            Library.shared.synchronize()
            Downloads.shared.run()
            await Reminders.reschedule(ask: false)
        }
    }

    func enteredBackground() {
        guard started else { return }
        scheduleRefresh()
        Task { await BackgroundWork.run("pods-report") { await self.uploadReport(reason: "background") } }
    }

    /// iOS runs this now and then while the app is in the background, roughly as often as it is used.
    func backgroundRefresh() async {
        guard !testing else { return }
        scheduleRefresh()
        DeviceLog.write("background refresh")
        _ = Transfers.shared
        // iOS allows about 30 seconds; whatever is still running carries on if the app stays awake.
        await BackgroundWork.waitAtMost(25) {
            await Reminders.reschedule(ask: false)
            await Library.shared.synchronizeAndWait(force: false)
            await Downloads.shared.runNow()
            await self.uploadReport(reason: "refresh")
        }
    }

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { DeviceLog.write("background refresh not scheduled: \(error.localizedDescription)") }
    }

    /// Runs every two seconds: cheap checks only.
    private func follow() {
        let library = Library.shared
        if library.revision != lastRevision {
            lastRevision = library.revision
            Downloads.shared.run()
            Player.shared.restore()
            writeStatus()
        }
        // The app only runs while it is on screen or playing, so this is not a background drain.
        if Date().timeIntervalSince(lastSync) >= 60 {
            lastSync = Date()
            library.synchronize()
            Downloads.shared.run()
        }
        if library.device.lastSync != nil, lastReport.map({ Date().timeIntervalSince($0) >= Self.reportInterval }) ?? true {
            let reason = lastReport == nil ? "launch" : "timer"
            lastReport = Date()
            Task { await uploadReport(reason: reason) }
        }
    }

    private func status() -> [String: Any] {
        let library = Library.shared, downloads = Downloads.shared
        return [
            "at": Date().timeIntervalSince1970,
            "paired": library.pairing == .paired,
            "episodes": library.episodes.count,
            "listen": library.listen.count,
            "shows": library.shows.count,
            "downloaded": library.listen.filter(downloads.isDownloaded).count,
            "downloading": downloads.progress.count,
            "downloadErrors": downloads.errors.count,
            "usedBytes": downloads.usedBytes,
            "pendingChanges": library.pendingChanges,
            "lastSync": library.device.lastSync ?? 0,
            "lastError": library.lastError ?? "",
            "downloadNotice": downloads.notice ?? "",
            "playing": Player.shared.current?.id ?? 0,
            "signingExpiresAt": Signing.expiry?.timeIntervalSince1970 ?? 0,
        ]
    }

    /// A small status file the Mac can read back after an install to confirm the app works.
    private func writeStatus() { DeviceLog.writeStatus(status()) }

    /// Send the status and the log's tail to the Mac, which keeps the latest per device in
    /// `Diagnostics/devices/`. Only after a sync, since the Mac accepts reports from known devices.
    func uploadReport(reason: String) async {
        let library = Library.shared
        guard !library.readOnly, library.pairing == .paired, library.device.lastSync != nil else { return }
        lastReport = Date()
        let payload: [String: Any] = [
            "reason": reason, "app": MacClient.userAgent, "simulator": Self.isSimulator, "status": status(),
            "log": DeviceLog.tail(64 * 1024),
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        do {
            let (_, http) = try await MacClient.shared.request("/devices/\(library.device.client_id)/report", method: "PUT",
                                                               body: body, timeout: 20)
            if http.statusCode != 204 { DeviceLog.write("report not saved status=\(http.statusCode)") }
        } catch {
            // The Mac is out of reach; the next report carries the same log.
        }
    }
}
