import SwiftUI

@main
struct PodsSpeakerApp: App {
    var body: some Scene {
        MenuBarExtra("Pods Pipeline", systemImage: "waveform") {
            PipelineMenu()
        }
        .menuBarExtraStyle(.window)
    }
}
