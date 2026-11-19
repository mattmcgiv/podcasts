import SwiftUI

struct SettingsView: View {
    @Environment(Library.self) private var library
    @Environment(Downloads.self) private var downloads
    @Environment(Player.self) private var player
    @State private var carOutput: (key: String, name: String)?
    @State private var knownCars: [String] = []
    @State private var refreshing = false
    @State private var confirmingRemove = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    Picker("Speed", selection: Binding(get: { library.speed }, set: { player.setSpeed($0) })) {
                        ForEach(Player.speeds, id: \.self) { Text(Format.speed($0)).tag($0) }
                    }
                    Toggle("Play the next episode automatically", isOn: Binding(get: { library.autoplay }, set: { library.setSetting("autoplay", .bool($0)) }))
                }
                Section {
                    if let carOutput {
                        let known = knownCars.contains(carOutput.key)
                        Toggle("“\(carOutput.name)” is my car", isOn: Binding(get: { known }, set: { on in
                            var list = player.car.knownDevices.filter { $0 != carOutput.key }
                            if on { list.append(carOutput.key) }
                            player.car.knownDevices = list
                            knownCars = list
                        }))
                    } else {
                        Text("Connect to the car's Bluetooth, then return here to mark it.").foregroundStyle(.secondary)
                    }
                    if !knownCars.isEmpty {
                        Button("Forget marked cars", role: .destructive) { player.car.knownDevices = []; knownCars = [] }
                    }
                } header: { Text("Car") } footer: {
                    Text("When a marked car reconnects within four hours of cutting playback off, the same episode resumes.")
                }
                downloadsSection
                Section("Mac") {
                    LabeledContent("Last sync", value: library.device.lastSync.map { Date(timeIntervalSince1970: $0).formatted(.relative(presentation: .named)) } ?? "Never")
                    if library.pendingChanges > 0 { LabeledContent("Changes waiting to send", value: "\(library.pendingChanges)") }
                    if let error = library.lastError { Text(error).font(.footnote).foregroundStyle(.orange) }
                    Button {
                        refreshing = true
                        Task { await library.refreshFeeds(); refreshing = false }
                    } label: {
                        HStack { Text("Check feeds now"); Spacer(); if refreshing || library.syncing { ProgressView() } }
                    }
                    .disabled(refreshing)
                }
                if !library.rejectedChanges.isEmpty {
                    Section {
                        ForEach(library.rejectedChanges) { change in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(change.entity) · \(change.field)").font(.subheadline).lineLimit(2)
                                Text(change.error ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            .swipeActions { Button("Discard", role: .destructive) { library.discard(change) } }
                        }
                    } header: { Text("Changes the Mac refused") } footer: { Text("Swipe to discard.") }
                }
                Section {
                    LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                    if let expiry = Signing.expiry {
                        LabeledContent("Signature expires", value: expiry.formatted(.dateTime.weekday().month().day().hour().minute()))
                            .foregroundStyle(expiry.timeIntervalSinceNow < 2 * 86400 ? .orange : .primary)
                    }
                } header: { Text("App") } footer: {
                    if Signing.expiry != nil { Text("The Mac re-signs the app before this date when both are on the same network.") }
                }
            }
            .navigationTitle("Settings")
            .onAppear(perform: readRoute)
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: DispatchQueue.main)) { _ in readRoute() }
            .miniPlayerInset()
        }
    }

    private var downloadsSection: some View {
        let preferences = library.device.preferences
        return Section {
            Toggle("Download new episodes", isOn: Binding(get: { preferences.automatic }, set: { value in
                var next = preferences; next.automatic = value; library.setPreferences(next); downloads.run()
            }))
            Picker("Keep up to", selection: Binding(get: { preferences.count }, set: { value in
                var next = preferences; next.count = value; library.setPreferences(next); downloads.run()
            })) {
                ForEach([5, 10, 25, 50, 100], id: \.self) { Text("\($0) episodes").tag($0) }
            }
            Picker("Storage limit", selection: Binding(get: { preferences.limit }, set: { value in
                var next = preferences; next.limit = value; library.setPreferences(next); downloads.run()
            })) {
                ForEach([1, 2, 5, 10, 20], id: \.self) { Text("\($0) GB").tag($0 * 1024 * 1024 * 1024) }
            }
            LabeledContent("Used", value: Format.bytes(downloads.usedBytes))
            if let notice = downloads.notice { Text(notice).font(.footnote).foregroundStyle(.orange) }
            Button("Remove all downloads", role: .destructive) { confirmingRemove = true }
                .confirmationDialog("Remove every downloaded episode from this iPhone?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                    Button("Remove downloads", role: .destructive) { player.close { downloads.removeAll() } }
                }
        } header: { Text("Downloads") }
    }

    private func readRoute() {
        knownCars = player.car.knownDevices
        carOutput = player.car.currentBluetoothOutput().map { (CarResume.deviceKey($0), $0.portName) }
    }
}

import AVFoundation

/// Reads when the free-account signature runs out, from the profile Xcode embeds in the app.
enum Signing {
    static let expiry: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()
}
