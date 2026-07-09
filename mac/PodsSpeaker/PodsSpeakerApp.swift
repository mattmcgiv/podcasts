import AppKit
import SwiftUI

@main
struct PodsSpeakerApp: App {
    @NSApplicationDelegateAdaptor(SpeakerAppDelegate.self) private var appDelegate
    @StateObject private var bootstrap = SpeakerBootstrap()

    var body: some Scene {
        MenuBarExtra("Pods Speaker", systemImage: "hifispeaker.fill") {
            SpeakerMenu(player: bootstrap.player, server: bootstrap.server)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Ensures Bonjour advertising starts at process launch (login item / open -a), not only
/// when the user opens the menu bar window. Relying on menu `onAppear` left the phone
/// stuck on "Mac (offline)" after silent launches.
final class SpeakerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            SpeakerBootstrap.shared?.startIfNeeded()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            SpeakerBootstrap.shared?.startIfNeeded()
        }
        return true
    }
}

@MainActor
final class SpeakerBootstrap: ObservableObject {
    static weak var shared: SpeakerBootstrap?

    let player: SpeakerPlayer
    let server: CastServer
    private var didStart = false

    init() {
        let player = SpeakerPlayer()
        self.player = player
        let server = CastServer(player: player)
        server.attachPlayerEvents()
        self.server = server
        SpeakerBootstrap.shared = self
        // Start immediately: MenuBarExtra content is not created until the icon is clicked,
        // so onAppear-based start never ran for login-item / background launches.
        startIfNeeded()
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        server.start()
    }
}

struct SpeakerMenu: View {
    @ObservedObject var player: SpeakerPlayer
    @ObservedObject var server: CastServer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pods Speaker")
                .font(.headline)
            Text(server.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(server.clientLabel)
                .font(.caption)
            Text(player.nowPlayingTitle)
                .lineLimit(2)
            if !player.nowPlayingArtist.isEmpty {
                Text(player.nowPlayingArtist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Divider()
            Button(player.isPlaying ? "Pause" : "Play") {
                player.togglePlayPause()
            }
            Button("Disconnect phone") {
                server.disconnectClient()
            }
            Button("Quit Pods Speaker") {
                server.stop()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
