import SwiftUI

@main
struct AgenticIDEApp: App {
    init() {
        GhosttyApp.shared.bootstrap()
    }

    var body: some Scene {
        WindowGroup("Agentic IDE") {
            ContentView()
                .frame(minWidth: 600, minHeight: 400)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 700)
    }
}
