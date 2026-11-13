import SwiftUI

@main
struct PodsApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(Library.shared)
                .environment(Downloads.shared)
                .environment(Player.shared)
                .task { await coordinator.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { coordinator.becameActive() }
                }
        }
    }
}

/// Ties the pieces together: pair, sync on a timer and on foreground, and keep
/// the download queue following the library.
@MainActor @Observable
final class AppCoordinator {
    @ObservationIgnored private var started = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var lastRevision = -1

    func start() async {
        guard !started else { return }
        started = true
        DeviceLog.write("launch version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") build=\(Bundle.main.object(forInfoDictionaryKey: "PodsBuildID") ?? "?")")
        _ = Player.shared
        await Library.shared.adoptDeliveredPairCode()
        Library.shared.synchronize()
        Player.shared.restore()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.follow()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func becameActive() {
        guard started else { return }
        Task {
            await Library.shared.adoptDeliveredPairCode()
            Library.shared.synchronize()
            Downloads.shared.run()
        }
    }

    @ObservationIgnored private var lastSync = Date()

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
    }

    /// A small status file the Mac can read back after an install to confirm the app works.
    private func writeStatus() {
        let library = Library.shared, downloads = Downloads.shared
        DeviceLog.writeStatus([
            "at": Date().timeIntervalSince1970,
            "paired": library.pairing == .paired,
            "episodes": library.episodes.count,
            "listen": library.listen.count,
            "shows": library.shows.count,
            "downloaded": library.listen.filter(downloads.isDownloaded).count,
            "pendingChanges": library.pendingChanges,
            "lastSync": library.device.lastSync ?? 0,
            "lastError": library.lastError ?? "",
            "downloadNotice": downloads.notice ?? "",
            "playing": Player.shared.current?.id ?? 0,
        ])
    }
}
