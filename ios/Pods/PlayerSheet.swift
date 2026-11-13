import SwiftUI

struct PlayerSheet: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var scrub: Double?

    var body: some View {
        if let episode = player.current {
            ScrollView {
                VStack(spacing: 22) {
                    Artwork(url: episode.artworkURL, size: 260)
                        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                        .padding(.top, 28)
                    VStack(spacing: 4) {
                        Text(episode.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        Text(episode.podcast_title).font(.subheadline).foregroundStyle(.secondary)
                    }
                    scrubber
                    transport
                    HStack {
                        Menu {
                            ForEach(Player.speeds, id: \.self) { value in
                                Button { player.setSpeed(value) } label: {
                                    if value == player.speed { Label(Format.speed(value), systemImage: "checkmark") } else { Text(Format.speed(value)) }
                                }
                            }
                        } label: {
                            Text(Format.speed(player.speed)).font(.body.weight(.semibold).monospacedDigit())
                                .frame(minWidth: 56, minHeight: 44)
                        }
                        .accessibilityLabel("Playback speed")
                        Spacer()
                        Button { player.markCurrentPlayed() } label: {
                            Label("Mark played", systemImage: "checkmark.circle").frame(minHeight: 44)
                        }
                    }
                    chapters(for: episode)
                }
                .padding(.horizontal, 24).padding(.bottom, 32)
            }
            .presentationDragIndicator(.visible)
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }

    private var scrubber: some View {
        let length = max(player.duration, 1)
        let shown = scrub ?? min(player.position, length)
        return VStack(spacing: 2) {
            Slider(value: Binding(get: { shown }, set: { scrub = $0 }), in: 0...length) { editing in
                if !editing, let target = scrub { player.seek(to: target); scrub = nil }
            }
            .accessibilityLabel("Position")
            .accessibilityValue(Format.clock(shown))
            HStack {
                Text(Format.clock(shown))
                Spacer()
                Text("−" + Format.clock(max(0, length - shown) / max(player.speed, 0.1)))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 44) {
            Button { player.skip(-Player.skipBack) } label: { Image(systemName: "gobackward.15").font(.system(size: 30)) }
                .accessibilityLabel("Back 15 seconds")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 72))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.skip(Player.skipForward) } label: { Image(systemName: "goforward.30").font(.system(size: 30)) }
                .accessibilityLabel("Forward 30 seconds")
        }
        .tint(.primary)
    }

    @ViewBuilder private func chapters(for episode: Episode) -> some View {
        let notes = (episode.show_notes ?? []).filter { $0.start_time.isFinite && $0.start_time >= 0 }.sorted { $0.start_time < $1.start_time }
        if !notes.isEmpty {
            let active = notes.last { $0.start_time <= player.position }?.id
            VStack(alignment: .leading, spacing: 0) {
                Text("Chapters").font(.headline).padding(.bottom, 6)
                ForEach(notes) { note in
                    Button { player.seek(to: note.start_time) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(Format.clock(note.start_time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title).font(.subheadline.weight(note.id == active ? .semibold : .regular))
                                    .foregroundStyle(note.id == active ? Color.accentColor : .primary)
                                if !note.summary.isEmpty { Text(note.summary).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                        }
                        .multilineTextAlignment(.leading)
                        .padding(.vertical, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
