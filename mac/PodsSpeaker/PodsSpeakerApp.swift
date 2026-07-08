import AppKit
import SwiftUI

@main
struct PodsSpeakerApp: App {
    @StateObject private var bootstrap = SpeakerBootstrap()

    var body: some Scene {
        MenuBarExtra("Pods Speaker", systemImage: "hifispeaker.fill") {
            SpeakerMenu(player: bootstrap.player, server: bootstrap.server)
                .onAppear {
                    bootstrap.startIfNeeded()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class SpeakerBootstrap: ObservableObject {
    let player: SpeakerPlayer
    let server: CastServer
    private var didStart = false

    init() {
        let player = SpeakerPlayer()
        self.player = player
        self.server = CastServer(player: player)
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
