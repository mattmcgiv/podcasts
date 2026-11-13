import SwiftUI

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        Group {
            if library.pairing == .unpaired {
                PairingView()
            } else {
                TabView {
                    Tab("Listen", systemImage: "headphones") { ListenView() }
                    Tab("Played", systemImage: "checkmark.circle") { PlayedView() }
                    Tab("Shows", systemImage: "square.stack") { ShowsView() }
                    Tab("Settings", systemImage: "gearshape") { SettingsView() }
                }
            }
        }
        .sheet(isPresented: $player.expanded) { PlayerSheet() }
    }
}

struct ListenView: View {
    @Environment(Library.self) private var library
    @Environment(Downloads.self) private var downloads
    @Environment(Player.self) private var player
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                SyncBanner()
                ForEach(library.listen) { episode in
                    Button { player.play(episode, context: .listen) } label: { EpisodeRow(episode: episode) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button { library.setPlayed(episode, true) } label: { Label("Played", systemImage: "checkmark") }.tint(.green)
                        }
                        .swipeActions(edge: .leading) {
                            if !downloads.isDownloaded(episode) {
                                Button { downloads.request(episode) } label: { Label("Download", systemImage: "arrow.down") }.tint(.blue)
                            }
                        }
                }
            }
            .listStyle(.plain)
            .overlay {
                if library.listen.isEmpty {
                    ContentUnavailableView(library.snapshot == nil ? "Waiting for the Mac" : "All caught up",
                                           systemImage: library.snapshot == nil ? "desktopcomputer" : "checkmark.circle",
                                           description: Text(library.snapshot == nil ? "The library appears after the first sync." : "New episodes appear here once the Mac has prepared them."))
                }
            }
            .navigationTitle("Listen")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add")
                }
            }
            .refreshable { await library.refreshFeeds() }
            .sheet(isPresented: $adding) { AddSheet() }
            .miniPlayerInset()
        }
    }
}

struct PlayedView: View {
    @Environment(Library.self) private var library

    var body: some View {
        NavigationStack {
            List(library.played.prefix(200)) { episode in
                EpisodeRow(episode: episode)
                    .swipeActions(edge: .trailing) {
                        Button { library.setPlayed(episode, false) } label: { Label("Unplayed", systemImage: "arrow.uturn.backward") }.tint(.blue)
                    }
            }
            .listStyle(.plain)
            .overlay { if library.played.isEmpty { ContentUnavailableView("Nothing played yet", systemImage: "checkmark.circle") } }
            .navigationTitle("Played")
            .refreshable { await library.synchronizeAndWait() }
            .miniPlayerInset()
        }
    }
}

struct ShowsView: View {
    @Environment(Library.self) private var library
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List(library.shows) { show in
                NavigationLink(value: show.id) {
                    HStack(spacing: 12) {
                        Artwork(url: show.image_url.flatMap(URL.init(string:)))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(show.title).font(.body.weight(.medium)).lineLimit(2)
                            if let unplayed = show.unplayed_count, unplayed > 0 {
                                Text("\(unplayed) unplayed").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay { if library.shows.isEmpty { ContentUnavailableView("No shows", systemImage: "square.stack", description: Text("Add a show by its feed address.")) } }
            .navigationTitle("Shows")
            .navigationDestination(for: Int.self) { ShowDetail(showID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add")
                }
            }
            .sheet(isPresented: $adding) { AddSheet() }
            .refreshable { await library.refreshFeeds() }
            .miniPlayerInset()
        }
    }
}

struct ShowDetail: View {
    let showID: Int
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    var body: some View {
        let show = library.shows.first { $0.id == showID }
        let episodes = library.episodes.filter { $0.podcast_id == showID }.sorted { $0.published_at > $1.published_at }
        List {
            if let show {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        Artwork(url: show.image_url.flatMap(URL.init(string:)), size: 96)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(show.title).font(.title3.weight(.semibold))
                            if let text = show.description, !text.isEmpty {
                                Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(5)
                            }
                        }
                    }
                    .listRowSeparator(.hidden)
                }
            }
            Section("Episodes") {
                ForEach(episodes) { episode in
                    Button {
                        if episode.isUnplayed { player.play(episode, context: .show) }
                    } label: { EpisodeRow(episode: episode).opacity(episode.isUnplayed ? 1 : 0.55) }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        if episode.played_at == nil {
                            Button { library.setPlayed(episode, true) } label: { Label("Played", systemImage: "checkmark") }.tint(.green)
                        } else {
                            Button { library.setPlayed(episode, false) } label: { Label("Unplayed", systemImage: "arrow.uturn.backward") }.tint(.blue)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(show?.title ?? "Show")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if show != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Unsubscribe", systemImage: "minus.circle", role: .destructive) { confirming = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .confirmationDialog("Unsubscribe from this show?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Unsubscribe", role: .destructive) {
                if let show { library.unsubscribe(show) }
                dismiss()
            }
        }
        .miniPlayerInset()
    }
}

/// Subscribe by feed address, or send a video link to the Mac. There is no search or directory.
struct AddSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var kind = Kind.feed
    enum Kind: String, CaseIterable { case feed = "Podcast feed", video = "Video" }

    private var url: String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: value), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Kind", selection: $kind) { ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented)
                Section {
                    TextField("https://", text: $text, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Paste") { text = UIPasteboard.general.string ?? text }
                } footer: {
                    Text(kind == .feed ? "The Mac subscribes and prepares new episodes." : "The Mac fetches the video's audio and adds it to Listen.")
                }
            }
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let url else { return }
                        if kind == .feed { library.subscribe(url) } else { library.addVideo(url) }
                        dismiss()
                    }
                    .disabled(url == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct PairingView: View {
    @Environment(Library.self) private var library
    @State private var code = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "desktopcomputer").font(.system(size: 52)).foregroundStyle(.secondary)
            Text("Pair with the Mac").font(.title2.weight(.semibold))
            Text("Installing from the Mac pairs this iPhone automatically. To pair by hand, run “manage.py pair” on the Mac and enter the code.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            TextField("Pairing code", text: $code)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.body.monospaced()).multilineTextAlignment(.center)
                .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            if let error { Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
            Button {
                working = true; error = nil
                Task {
                    do { try await library.pair(code: code) } catch let failure { error = failure.localizedDescription }
                    working = false
                }
            } label: {
                Group { if working { ProgressView() } else { Text("Pair") } }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(working || code.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Paste code") { code = UIPasteboard.general.string ?? code }.font(.subheadline)
            Spacer(); Spacer()
        }
        .padding(28)
    }
}
