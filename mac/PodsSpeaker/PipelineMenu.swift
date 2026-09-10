import AppKit
import SwiftUI
import SQLite3

struct PipelineEpisode: Decodable, Identifiable {
    let id: String
    let episodeId: Int
    let title: String
    let podcastTitle: String
    let stage: String
    let blockingReason: String?
    let lastErrorMessage: String?
    let completedUnits: Int?
    let totalUnits: Int?

    var needsAttention: Bool { ["failed", "blocked", "review"].contains(stage) || blockingReason != nil }
    var isWaiting: Bool { ["queued", "downloaded", "retry"].contains(stage) || ["memory_busy", "omlx_busy"].contains(lastErrorMessage ?? "") }
    var progress: Double? {
        guard let completedUnits, let totalUnits, totalUnits > 0,
              completedUnits >= 0, completedUnits <= totalUnits else { return nil }
        return Double(completedUnits) / Double(totalUnits)
    }
    var stageLabel: String {
        switch stage {
        case "queued": return "Waiting to download"
        case "downloading": return "Downloading audio"
        case "downloaded": return "Waiting to transcribe"
        case "transcribing": return "Transcribing"
        case "classifying": return "Finding ad breaks"
        case "failed": return "Processing failed"
        case "blocked", "review": return "Needs attention"
        case "retry": return "Waiting to retry"
        default: return stage.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    var attentionLabel: String {
        if let blockingReason { return blockingReason.replacingOccurrences(of: "_", with: " ").capitalized }
        return lastErrorMessage ?? "Processing failed"
    }

    var isInProgress: Bool { ["downloading", "transcribing", "classifying"].contains(stage) && !needsAttention }
    var displayStage: String {
        if lastErrorMessage == "memory_busy" { return "\(stageLabel) · paused for memory" }
        if lastErrorMessage == "omlx_busy" { return "\(stageLabel) · waiting for local AI" }
        return stageLabel
    }
}

struct PipelinePresentation {
    let items: [PipelineEpisode]
    var featured: [PipelineEpisode] {
        let processing = items.filter { !$0.needsAttention && !$0.isWaiting }
        let paused = items.filter { $0.isInProgress && $0.isWaiting }
        return Array((processing + paused).prefix(3))
    }
    var remaining: [PipelineEpisode] {
        let visible = Set(featured.map(\.id))
        return items.filter { !$0.needsAttention && !visible.contains($0.id) }
    }
}

struct PipelineRepository {
    var databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/pods/data/pods.sqlite")

    func snapshot() throws -> [PipelineEpisode] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        var columns: OpaquePointer?
        var hasProgress = false
        if sqlite3_prepare_v2(database, "SELECT completed_units,total_units FROM browser_pending_jobs LIMIT 0", -1, &columns, nil) == SQLITE_OK {
            hasProgress = true
        }
        sqlite3_finalize(columns)
        let sql = """
            SELECT j.episode_id, e.title, p.title, j.stage, j.error, \(hasProgress ? "j.completed_units,j.total_units" : "NULL,NULL")
            FROM browser_pending_jobs j JOIN episodes e ON e.id=j.episode_id
            JOIN podcasts p ON p.id=e.podcast_id
            ORDER BY j.priority DESC, e.published_at, e.id
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        func string(_ column: Int32) -> String? {
            guard let value = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: value)
        }
        var items: [PipelineEpisode] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return items }
            guard result == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
            let episodeID = Int(sqlite3_column_int64(statement, 0))
            items.append(PipelineEpisode(id: String(episodeID), episodeId: episodeID,
                title: string(1) ?? "Untitled episode", podcastTitle: string(2) ?? "Podcast",
                stage: string(3) ?? "queued", blockingReason: nil, lastErrorMessage: string(4),
                completedUnits: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 5)),
                totalUnits: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 6))))
        }
    }
}

@MainActor
final class PipelineMonitor: ObservableObject {
    @Published private(set) var items: [PipelineEpisode] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var unavailable = false
    @Published private(set) var refreshing = false

    var active: [PipelineEpisode] { items.filter { !$0.needsAttention && !$0.isWaiting } }
    var waiting: [PipelineEpisode] { items.filter { !$0.needsAttention && $0.isWaiting } }
    var attention: [PipelineEpisode] { items.filter(\.needsAttention) }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let snapshot = try await Task.detached(priority: .utility) { try PipelineRepository().snapshot() }.value
            guard !Task.isCancelled else { return }
            items = snapshot
            lastUpdated = Date()
            unavailable = false
        } catch {
            if !Task.isCancelled { unavailable = true }
        }
    }

    func poll() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }
}

private enum PipelineTheme {
    static let background = Color(red: 11/255, green: 13/255, blue: 16/255)
    static let surface = Color(red: 20/255, green: 24/255, blue: 29/255)
    static let blue = Color(red: 79/255, green: 156/255, blue: 249/255)
    static let muted = Color(red: 151/255, green: 161/255, blue: 173/255)
    static let line = Color.white.opacity(0.12)
    static let danger = Color(red: 1, green: 0.39, blue: 0.41)
}

struct PipelineMenu: View {
    @StateObject private var monitor = PipelineMonitor()
    @ObservedObject var player: SpeakerPlayer
    @ObservedObject var server: CastServer
    @State private var showSpeaker = false
    private var presentation: PipelinePresentation { PipelinePresentation(items: monitor.items) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 24)
            if monitor.unavailable {
                Text(monitor.lastUpdated == nil ? "Pipeline status unavailable" : "Showing last update · server unavailable")
                    .font(.system(size: 11)).foregroundStyle(PipelineTheme.danger)
                    .padding(.bottom, 10)
            }
            sectionHeading("PROCESSING NOW")
            rule.padding(.top, 9)
            // An explicit height prevents MenuBarExtra's intrinsic sizing from collapsing
            // the episode region. Rows also have fixed heights and cannot be compressed.
            VStack(spacing: 0) {
                if presentation.featured.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: monitor.items.isEmpty ? "checkmark.circle" : "pause.circle")
                            .font(.system(size: 25)).foregroundStyle(PipelineTheme.blue)
                        Text(monitor.lastUpdated == nil ? "Loading pipeline…" : monitor.items.isEmpty ? "All caught up" : "Waiting to process")
                            .font(.system(size: 14, weight: .medium))
                        Text(monitor.items.isEmpty ? "New episodes will appear here." : "Queued episodes will start when the server is ready.")
                            .font(.system(size: 12)).foregroundStyle(PipelineTheme.muted)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ForEach(Array(presentation.featured.enumerated()), id: \.element.id) { index, episode in
                        PipelineEpisodeRow(episode: episode, stale: monitor.unavailable, index: index)
                        rule
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 354)
            .fixedSize(horizontal: false, vertical: true)

            sectionHeading(presentation.remaining.contains(where: { !$0.isWaiting }) ? "MORE IN PIPELINE" : "WAITING")
                .padding(.top, 14)
            Text(waitingSummary)
                .font(.system(size: 12)).foregroundStyle(PipelineTheme.muted)
                .lineLimit(2).frame(height: 30, alignment: .topLeading)
                .padding(.top, 7)
            if let first = monitor.attention.first {
                HStack(spacing: 14) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 25))
                        .foregroundStyle(PipelineTheme.danger)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(monitor.attention.count) \(monitor.attention.count == 1 ? "item needs" : "items need") attention")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(PipelineTheme.danger)
                        Text("\(first.podcastTitle) · \(first.attentionLabel)")
                            .font(.system(size: 12)).foregroundStyle(PipelineTheme.muted)
                            .lineLimit(1).help("\(first.title)\n\(first.attentionLabel)")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).frame(height: 58)
                .background(PipelineTheme.danger.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(PipelineTheme.danger.opacity(0.45), lineWidth: 1))
                .padding(.top, 4)
            }
            Spacer(minLength: 10)
            rule.padding(.bottom, 10)
            footer
        }
        .padding(18)
        .frame(width: 440, height: 662, alignment: .topLeading)
        .background(PipelineTheme.background)
        .foregroundStyle(Color(red: 0.94, green: 0.96, blue: 0.98))
        .preferredColorScheme(.dark)
        .task { await monitor.poll() }
    }

    private var header: some View {
        HStack(spacing: 22) {
            Text("Pods").font(.system(size: 27, weight: .semibold))
            Rectangle().fill(PipelineTheme.line).frame(width: 1, height: 37)
            VStack(alignment: .leading, spacing: 5) {
                Text("Pipeline").font(.system(size: 19, weight: .semibold))
                HStack(spacing: 7) {
                    Circle().fill(monitor.unavailable ? PipelineTheme.muted : PipelineTheme.blue).frame(width: 9, height: 9)
                    Text("\(monitor.active.count + monitor.waiting.count) active · \(monitor.attention.count) needs attention")
                        .font(.system(size: 12)).foregroundStyle(PipelineTheme.muted)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var waitingSummary: String {
        let remaining = presentation.remaining
        guard !remaining.isEmpty else { return "No more episodes waiting" }
        let count = remaining.count
        if remaining.allSatisfy({ $0.lastErrorMessage == "memory_busy" }) {
            return "\(count) more \(count == 1 ? "episode is" : "episodes are") paused for memory"
        }
        return "\(count) more \(count == 1 ? "episode" : "episodes") in the server queue"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { NSWorkspace.shared.open(URL(string: "https://pods.mcgiv.dev")!) } label: {
                Text("Open Pods").font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
                    .frame(height: 38)
            }
            .buttonStyle(PipelineButtonStyle())
            Button { Task { await monitor.refresh() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 16)).frame(width: 38, height: 38)
            }
            .buttonStyle(PipelineButtonStyle()).disabled(monitor.refreshing)
            .help(monitor.lastUpdated.map { "Updated \($0.formatted(date: .omitted, time: .standard)) · Refresh pipeline" } ?? "Refresh pipeline")
            Button { showSpeaker.toggle() } label: {
                Image(systemName: "hifispeaker").font(.system(size: 16)).frame(width: 38, height: 38)
            }
            .buttonStyle(PipelineButtonStyle()).help("Speaker controls")
            .popover(isPresented: $showSpeaker) { SpeakerMenu(player: player, server: server) }
        }
    }

    private var rule: some View { Rectangle().fill(PipelineTheme.line).frame(height: 1) }
    private func sectionHeading(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).tracking(1.5).foregroundStyle(PipelineTheme.muted)
    }
}

private struct PipelineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Color.white : Color.white.opacity(0.88))
            .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(PipelineTheme.line, lineWidth: 1))
    }
}

private struct PipelineEpisodeRow: View {
    let episode: PipelineEpisode
    let stale: Bool
    let index: Int

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(PipelineTheme.surface)
                RoundedRectangle(cornerRadius: 8)
                    .fill(RadialGradient(colors: [tileColor.opacity(0.65), tileColor.opacity(0.1), .clear],
                                         center: .bottomLeading, startRadius: 0, endRadius: 80))
                Image(systemName: "waveform").font(.system(size: 22, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .frame(width: 64, height: 68)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.18), lineWidth: 1))
            VStack(alignment: .leading, spacing: 5) {
                Text(episode.title).font(.system(size: 14, weight: .semibold))
                    .lineLimit(2).help(episode.title)
                Text(episode.podcastTitle).font(.system(size: 12))
                    .foregroundStyle(PipelineTheme.muted).lineLimit(1)
                HStack(spacing: 4) {
                    Text(episode.displayStage).lineLimit(1)
                    Spacer(minLength: 0)
                    if episode.isWaiting { Image(systemName: "pause.fill") }
                }.font(.system(size: 11)).foregroundStyle(PipelineTheme.muted)
                HStack(spacing: 8) {
                    PipelineProgressBar(progress: episode.progress, paused: episode.isWaiting || stale)
                    if let progress = episode.progress {
                        Text("\(Int(progress * 100))%").font(.system(size: 11)).foregroundStyle(PipelineTheme.muted)
                    }
                }.padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.vertical, 13)
        .frame(height: 117, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tileColor: Color { [PipelineTheme.blue, Color.orange, Color.mint][index % 3] }
}

private struct PipelineProgressBar: View {
    let progress: Double?
    let paused: Bool
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                if let progress {
                    Capsule().fill(PipelineTheme.blue).frame(width: geometry.size.width * progress)
                }
            }.clipShape(Capsule())
        }
        .frame(height: 7)
        .accessibilityLabel(progress.map { "\(Int($0 * 100)) percent" } ?? (paused ? "Paused; progress unavailable" : "Processing; progress unavailable"))
    }
}
