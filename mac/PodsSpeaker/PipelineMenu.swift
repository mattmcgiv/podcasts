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
    var isWaiting: Bool { ["queued", "downloaded", "retry"].contains(stage) || ["memory_busy", "omlx_busy", "power_unplugged", "power_status_unavailable"].contains(lastErrorMessage ?? "") }
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

    func displayStage(power: PipelinePower) -> String {
        if lastErrorMessage == "memory_busy" { return "\(stageLabel) · paused for memory" }
        if lastErrorMessage == "omlx_busy" { return "\(stageLabel) · waiting for local AI" }
        if lastErrorMessage == "power_unplugged" {
            return power == .battery ? "\(stageLabel) · paused until plugged in" : stageLabel
        }
        if lastErrorMessage == "power_status_unavailable" {
            return power == .external ? stageLabel : "\(stageLabel) · paused while checking power"
        }
        return stageLabel
    }
}

enum PipelinePower: Equatable {
    case external
    case battery
    case unknown

    static func parsePmset(_ output: String) -> PipelinePower {
        if let source = output
            .split(separator: "\n")
            .compactMap({ line -> Substring? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("Now drawing from '") else { return nil }
                return trimmed.dropFirst("Now drawing from '".count).split(separator: "'").first
            })
            .first
        {
            switch source {
            case "AC Power", "UPS Power": return .external
            case "Battery Power": return .battery
            default: return .unknown
            }
        }
        return .unknown
    }

    static func sample() -> PipelinePower {
        parsePmset(pmsetOutput())
    }

    private static func pmsetOutput() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

struct PipelinePresentation {
    let items: [PipelineEpisode]
    var processing: [PipelineEpisode] { items.filter { !$0.needsAttention && !$0.isWaiting } }
    var queued: [PipelineEpisode] { items.filter { !$0.needsAttention && $0.isWaiting } }
    var stuck: [PipelineEpisode] { items.filter(\.needsAttention) }
    func statusSummary(visibleStuckCount: Int) -> String {
        "\(processing.count) processing · \(queued.count) queued · \(visibleStuckCount) stuck"
    }
    var statusSummary: String { statusSummary(visibleStuckCount: stuck.count) }
}

enum PipelineAttentionDismissals {
    static let defaultsKey = "dismissedPipelineAttentionEpisodeIDs"

    static func load(from defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    static func save(_ episodeIDs: Set<String>, to defaults: UserDefaults = .standard) {
        defaults.set(episodeIDs.sorted(), forKey: defaultsKey)
    }

    static func signature(_ episode: PipelineEpisode) -> String {
        "\(episode.id)\u{1f}\(episode.lastErrorMessage ?? episode.stage)"
    }

    static func visibleAttention(in items: [PipelineEpisode], dismissedEpisodeIDs: Set<String>) -> [PipelineEpisode] {
        items.filter { $0.needsAttention && !dismissedEpisodeIDs.contains(signature($0)) }
    }
}

enum PipelineAttentionPaging {
    static let pageSize = 5

    static func pageCount(itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return (itemCount + pageSize - 1) / pageSize
    }

    static func clamp(page: Int, itemCount: Int) -> Int {
        let pages = pageCount(itemCount: itemCount)
        guard pages > 0 else { return 0 }
        return min(max(page, 0), pages - 1)
    }

    static func slice(_ items: [PipelineEpisode], page: Int) -> [PipelineEpisode] {
        let pageIndex = clamp(page: page, itemCount: items.count)
        let start = pageIndex * pageSize
        guard start < items.count else { return [] }
        return Array(items[start..<min(start + pageSize, items.count)])
    }

    static func summary(itemCount: Int, page: Int) -> String {
        guard itemCount > 0 else { return "0 of 0" }
        let pageIndex = clamp(page: page, itemCount: itemCount)
        let start = pageIndex * pageSize + 1
        let end = min((pageIndex + 1) * pageSize, itemCount)
        return "\(start)-\(end) of \(itemCount)"
    }
}

struct PipelineTroubleshootLaunch: Equatable {
    let prompt: String
    let promptURL: URL
    let scriptURL: URL
    let openArguments: [String]
}

enum PipelineTroubleshoot {
    static let model = "grok-4.6"
    static let reasoningEffort = "high"
    static let ghosttyURL = URL(fileURLWithPath: "/Applications/Ghostty.app")

    static var homeURL: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var repositoryURL: URL { homeURL.appendingPathComponent("projects/podcasts") }
    static var grokURL: URL { homeURL.appendingPathComponent(".grok/bin/grok") }
    static var databaseURL: URL { homeURL.appendingPathComponent(".local/share/pods/data/pods.sqlite") }
    static var serviceLogURL: URL { homeURL.appendingPathComponent(".local/share/pods/service.log") }

    static func prompt(for episode: PipelineEpisode) -> String {
        let progress: String
        if let value = episode.progress {
            progress = "\(Int(value * 100))%"
        } else if let completed = episode.completedUnits, let total = episode.totalUnits {
            progress = "\(completed)/\(total)"
        } else {
            progress = "unknown"
        }
        return """
        Investigate this Pods pipeline item that needs attention. Work in \(repositoryURL.path). Diagnose first. Do not mutate the live SQLite database, retry jobs, deploy, or change production data unless I explicitly ask after you report.

        Episode ID: \(episode.episodeId)
        Title: \(episode.title)
        Podcast: \(episode.podcastTitle)
        Pipeline stage: \(episode.stage) (\(episode.stageLabel))
        Attention: \(episode.attentionLabel)
        Last error: \(episode.lastErrorMessage ?? "none")
        Blocking reason: \(episode.blockingReason ?? "none")
        Progress: \(progress)

        The menu bar reads pending jobs from:
        \(databaseURL.path)
        using browser_pending_jobs joined to episodes and podcasts.

        Service log:
        \(serviceLogURL.path)

        Please:
        1. Confirm the current job/episode row and related log lines with evidence.
        2. Explain why this item is in the attention list (failed, blocked, review, or a blocking reason).
        3. Identify the smallest likely fix or retry path.
        4. Stop after the diagnosis unless I ask you to implement or repair.
        """
    }

    static func ghosttyOpenArguments(scriptURL: URL, repositoryURL: URL = repositoryURL) -> [String] {
        [
            "-na", "Ghostty.app",
            "--args",
            "--working-directory=\(repositoryURL.path)",
            "--window-save-state=never",
            "--quit-after-last-window-closed=true",
            "--initial-command=direct:\(scriptURL.path)",
        ]
    }

    static func prepare(
        for episode: PipelineEpisode,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> PipelineTroubleshootLaunch {
        let folder = directory ?? fileManager.temporaryDirectory
            .appendingPathComponent("pods-troubleshoot-\(episode.episodeId)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let prompt = prompt(for: episode)
        let promptURL = folder.appendingPathComponent("prompt.txt")
        let scriptURL = folder.appendingPathComponent("launch.zsh")
        try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
        let script = """
        #!/bin/zsh
        set -euo pipefail
        export PATH=\(shellQuote(grokURL.deletingLastPathComponent().path)):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
        cd -- \(shellQuote(repositoryURL.path))
        if [[ ! -x \(shellQuote(grokURL.path)) ]]; then
          print -u2 -- "grok CLI not found at \(grokURL.path)"
          print -n -- "Press any key to close."
          read -k
          exit 1
        fi
        set +e
        grok --cwd \(shellQuote(repositoryURL.path)) --model \(shellQuote(model)) --reasoning-effort \(shellQuote(reasoningEffort)) -- "$(< \(shellQuote(promptURL.path)))"
        status=$?
        set -e
        if (( status != 0 )); then
          print -u2 -- "grok exited ${status}"
          print -n -- "Press any key to close."
          read -k
        fi
        exit "${status}"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return PipelineTroubleshootLaunch(
            prompt: prompt,
            promptURL: promptURL,
            scriptURL: scriptURL,
            openArguments: ghosttyOpenArguments(scriptURL: scriptURL, repositoryURL: repositoryURL)
        )
    }

    @discardableResult
    static func open(for episode: PipelineEpisode) throws -> PipelineTroubleshootLaunch {
        let launch = try prepare(for: episode)
        guard FileManager.default.fileExists(atPath: ghosttyURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = launch.openArguments
        try process.run()
        return launch
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    @Published private(set) var power: PipelinePower = .unknown
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var unavailable = false
    @Published private(set) var refreshing = false

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let power = await Task.detached(priority: .utility) { PipelinePower.sample() }.value
        if !Task.isCancelled { self.power = power }
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
    @State private var dismissedAttentionIDs = PipelineAttentionDismissals.load()
    @State private var attentionPage = 0
    @State private var troubleshootError: String?
    private var presentation: PipelinePresentation { PipelinePresentation(items: monitor.items) }
    private var attention: [PipelineEpisode] {
        PipelineAttentionDismissals.visibleAttention(in: monitor.items, dismissedEpisodeIDs: dismissedAttentionIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 24)
            if monitor.unavailable {
                Text(monitor.lastUpdated == nil ? "Pipeline status unavailable" : "Showing last update · server unavailable")
                    .font(.system(size: 11)).foregroundStyle(PipelineTheme.danger)
                    .padding(.bottom, 10)
            }
            sectionHeading("PROCESSING")
            rule.padding(.top, 9)
            if presentation.processing.isEmpty {
                emptyState(monitor.lastUpdated == nil ? "Loading pipeline…" : "Nothing processing")
            } else {
                ForEach(Array(presentation.processing.enumerated()), id: \.element.id) { index, episode in
                    PipelineEpisodeRow(episode: episode, stale: monitor.unavailable, index: index, power: monitor.power)
                    rule
                }
            }

            sectionHeading("QUEUE")
                .padding(.top, 14)
            rule.padding(.top, 9)
            if presentation.queued.isEmpty {
                emptyState(monitor.lastUpdated == nil ? "Loading pipeline…" : "Nothing queued")
            } else {
                ForEach(Array(presentation.queued.enumerated()), id: \.element.id) { index, episode in
                    PipelineEpisodeRow(episode: episode, stale: monitor.unavailable, index: index, power: monitor.power)
                    rule
                }
            }

            if !attention.isEmpty {
                sectionHeading("STUCK")
                    .padding(.top, 14)
                rule.padding(.top, 9)
                PipelineAttentionList(
                    items: attention,
                    page: $attentionPage,
                    error: troubleshootError,
                    onDismiss: dismiss,
                    onTroubleshoot: troubleshoot
                )
                .padding(.top, 10)
            }
        }
        .onChange(of: attention.count) { _, count in
            attentionPage = PipelineAttentionPaging.clamp(page: attentionPage, itemCount: count)
            if count == 0 {
                troubleshootError = nil
            }
        }
        .padding(18)
        .frame(width: 440, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
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
                    Text(presentation.statusSummary(visibleStuckCount: attention.count))
                        .font(.system(size: 12)).foregroundStyle(PipelineTheme.muted)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var rule: some View { Rectangle().fill(PipelineTheme.line).frame(height: 1) }
    private func sectionHeading(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).tracking(1.5).foregroundStyle(PipelineTheme.muted)
    }
    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(PipelineTheme.muted)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func dismiss(_ episode: PipelineEpisode) {
        dismissedAttentionIDs.insert(PipelineAttentionDismissals.signature(episode))
        PipelineAttentionDismissals.save(dismissedAttentionIDs)
    }

    private func troubleshoot(_ episode: PipelineEpisode) {
        do {
            try PipelineTroubleshoot.open(for: episode)
            troubleshootError = nil
        } catch {
            troubleshootError = "Could not open Ghostty for \(episode.title)"
        }
    }
}

private struct PipelineAttentionList: View {
    let items: [PipelineEpisode]
    @Binding var page: Int
    let error: String?
    let onDismiss: (PipelineEpisode) -> Void
    let onTroubleshoot: (PipelineEpisode) -> Void

    private var pageCount: Int { PipelineAttentionPaging.pageCount(itemCount: items.count) }
    private var visible: [PipelineEpisode] { PipelineAttentionPaging.slice(items, page: page) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if pageCount > 1 {
                HStack {
                    Spacer(minLength: 0)
                    Text(PipelineAttentionPaging.summary(itemCount: items.count, page: page))
                        .font(.system(size: 11)).foregroundStyle(PipelineTheme.muted)
                }
                .padding(.bottom, 8)
            }
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, episode in
                if index > 0 {
                    Rectangle().fill(PipelineTheme.danger.opacity(0.18)).frame(height: 1)
                }
                PipelineAttentionRow(episode: episode, onDismiss: { onDismiss(episode) }, onTroubleshoot: { onTroubleshoot(episode) })
            }
            if pageCount > 1 {
                HStack(spacing: 12) {
                    Button("Previous") {
                        page = PipelineAttentionPaging.clamp(page: page - 1, itemCount: items.count)
                    }
                    .disabled(page <= 0)
                    .accessibilityLabel("Previous attention page")
                    Spacer(minLength: 0)
                    Text("Page \(page + 1) of \(pageCount)")
                    Spacer(minLength: 0)
                    Button("Next") {
                        page = PipelineAttentionPaging.clamp(page: page + 1, itemCount: items.count)
                    }
                    .disabled(page + 1 >= pageCount)
                    .accessibilityLabel("Next attention page")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PipelineTheme.muted)
                .padding(.top, 8)
            }
            if let error {
                Text(error)
                    .font(.system(size: 11)).foregroundStyle(PipelineTheme.danger)
                    .padding(.top, 8)
            }
        }
        .padding(12)
        .background(PipelineTheme.danger.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PipelineTheme.danger.opacity(0.45), lineWidth: 1))
    }
}

private struct PipelineAttentionRow: View {
    let episode: PipelineEpisode
    let onDismiss: () -> Void
    let onTroubleshoot: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(episode.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .help(episode.title)
            Text("\(episode.podcastTitle) · \(episode.attentionLabel)")
                .font(.system(size: 12))
                .foregroundStyle(PipelineTheme.muted)
                .lineLimit(2)
                .help("\(episode.title)\n\(episode.attentionLabel)")
            HStack(spacing: 10) {
                Button(action: onTroubleshoot) {
                    Text("Troubleshoot (AI)")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(PipelineTheme.blue.opacity(0.16), in: Capsule())
                        .overlay(Capsule().stroke(PipelineTheme.blue.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Troubleshoot \(episode.title) with AI")
                .help("Open a new Ghostty window with Grok 4.6 high in ~/projects/podcasts")
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Text("Dismiss").underline()
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PipelineTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss attention for \(episode.title)")
                .help("Permanently dismiss this issue from the pipeline menu")
            }
        }
        .padding(.vertical, 8)
    }
}

private struct PipelineEpisodeRow: View {
    let episode: PipelineEpisode
    let stale: Bool
    let index: Int
    let power: PipelinePower

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
                    Text(episode.displayStage(power: power)).lineLimit(1)
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
