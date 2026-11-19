import SwiftUI

/// The full player. Views that read the playhead are split out so the twice-a-second
/// position updates redraw only the scrubber and chapter highlight.
struct PlayerSheet: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let episode = player.current {
            ScrollView {
                VStack(spacing: 22) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Close player")
                        Spacer()
                    }
                    .tint(.primary)
                    .padding(.top, 8)
                    Artwork(url: episode.artworkURL, size: 260)
                        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                    VStack(spacing: 4) {
                        Text(episode.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                            .accessibilityIdentifier("player-title")
                        Text(episode.podcast_title).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Scrubber()
                    Transport()
                    VStack(spacing: 0) {
                        SpeedMenu()
                        Divider().padding(.leading, 34)
                        Menu {
                            ForEach([false, true], id: \.self) { mac in
                                Button {
                                    if mac != player.playingOnMac { player.switchOutput() }
                                } label: {
                                    if mac == player.playingOnMac {
                                        Label(mac ? "Mac" : "iPhone", systemImage: "checkmark")
                                    } else {
                                        Text(mac ? "Mac" : "iPhone")
                                    }
                                }
                            }
                        } label: {
                            ControlRow(title: "Play on", icon: "laptopcomputer",
                                       value: player.playingOnMac ? "Mac" : "iPhone")
                        }
                        .accessibilityLabel("Play on")
                        .accessibilityValue(player.playingOnMac ? "Mac" : "iPhone")
                        .disabled(library.readOnly || episode.manifest == nil)
                        Divider().padding(.leading, 34)
                        Button { player.markCurrentPlayed() } label: {
                            ControlRow(title: "Mark played", icon: "checkmark.circle")
                        }
                        .accessibilityLabel("Mark played")
                    }
                    .buttonStyle(.plain)
                    .disabled(player.speakerBusy)
                    .padding(.horizontal, 16)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                    if let error = player.speakerError {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                    Chapters(notes: (episode.show_notes ?? [])
                        .filter { $0.start_time.isFinite && $0.start_time >= 0 }
                        .sorted { $0.start_time < $1.start_time })
                }
                .padding(.horizontal, 24).padding(.bottom, 32)
            }
            .presentationDragIndicator(.visible)
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }
}

private struct Scrubber: View {
    @Environment(Player.self) private var player
    @State private var scrub: Double?

    var body: some View {
        let length = max(player.duration, 1)
        let shown = scrub ?? min(player.position, length)
        VStack(spacing: 2) {
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
            .accessibilityHidden(true)
        }
    }
}

private struct Transport: View {
    @Environment(Player.self) private var player

    var body: some View {
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
}

private struct ControlRow: View {
    let title: String
    let icon: String
    var value: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 22).accessibilityHidden(true)
            Text(title)
            Spacer(minLength: 6)
            if let value {
                HStack(spacing: 4) {
                    Text(value).monospacedDigit()
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(Rectangle())
    }
}

private struct SpeedMenu: View {
    @Environment(Player.self) private var player

    var body: some View {
        Menu {
            ForEach(Player.speeds, id: \.self) { value in
                Button { player.setSpeed(value) } label: {
                    if value == player.speed { Label(Format.speed(value), systemImage: "checkmark") } else { Text(Format.speed(value)) }
                }
            }
        } label: {
            ControlRow(title: "Playback speed", icon: "speedometer", value: Format.speed(player.speed))
        }
        .accessibilityLabel("Playback speed")
        .accessibilityValue(Format.speed(player.speed))
    }
}

private struct Chapters: View {
    let notes: [ShowNote]
    @Environment(Player.self) private var player

    var body: some View {
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
