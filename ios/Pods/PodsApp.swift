import SwiftUI

@main
struct PodsApp: App {
    var body: some Scene {
        WindowGroup {
            WebShell()
                .ignoresSafeArea()
        }
    }
}
