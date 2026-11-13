import SwiftUI

struct Artwork: View {
    let url: URL?
    var size: CGFloat = 56
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous).fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "waveform").foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
        .task(id: url) {
            image = nil
            if let url { image = await ArtworkCache.shared.image(for: url) }
        }
        .accessibilityHidden(true)
    }
}

enum Format {
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func length(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "under 1 min" }
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func day(_ unix: Double) -> String {
        Date(timeIntervalSince1970: unix).formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func speed(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))×" : String(format: "%.1f×", value)
    }
}

struct EpisodeRow: View {
    let episode: Episode
    @Environment(Downloads.self) private var downloads
    @Environment(Player.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: episode.artworkURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(episode.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(player.current?.id == episode.id ? Color.accentColor : .primary)
                Text(episode.podcast_title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    status
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private var detail: String {
        if let error = downloads.errors[episode.id] { return error }
        if let progress = downloads.progress[episode.id] {
            return "Downloading \(Format.bytes(progress.received)) of \(Format.bytes(progress.total))"
        }
        var parts: [String] = []
        if episode.duration > 0 {
            let left = episode.duration - episode.position_secs
            parts.append(episode.played_at == nil && episode.position_secs > 1 ? "\(Format.length(max(0, left))) left" : Format.length(episode.duration))
        }
        parts.append(Format.day(episode.published_at))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var status: some View {
        if downloads.errors[episode.id] != nil {
            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        } else if let progress = downloads.progress[episode.id] {
            ProgressView(value: Double(progress.received), total: Double(max(progress.total, 1)))
                .progressViewStyle(.circular).controlSize(.mini)
        } else if downloads.isDownloaded(episode) {
            Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.green)
                .accessibilityLabel("Downloaded")
        } else if episode.played_at == nil {
            Image(systemName: "icloud.and.arrow.down").font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("Not downloaded")
        }
    }
}

/// The bar above the tab bar while something is loaded.
struct MiniPlayer: View {
    @Environment(Player.self) private var player

    var body: some View {
        if let episode = player.current {
            HStack(spacing: 12) {
                Artwork(url: episode.artworkURL, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(episode.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(episode.podcast_title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.skip(Player.skipForward) } label: {
                    Image(systemName: "goforward.30").font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Skip forward 30 seconds")
            }
            .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .bottom) {
                GeometryReader { proxy in
                    Capsule().fill(Color.accentColor)
                        .frame(width: proxy.size.width * (player.duration > 0 ? min(1, player.position / player.duration) : 0), height: 2)
                }
                .frame(height: 2).padding(.horizontal, 16)
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
            .contentShape(Rectangle())
            .onTapGesture { player.expanded = true }
            .tint(.primary)
        }
    }
}

extension View {
    /// Keeps list content clear of the mini player.
    func miniPlayerInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayer() }
    }
}

struct SyncBanner: View {
    @Environment(Library.self) private var library
    @Environment(Downloads.self) private var downloads

    var body: some View {
        if let message = library.lastError ?? downloads.notice {
            Label(message, systemImage: "wifi.exclamationmark")
                .font(.footnote).foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
        }
    }
}
