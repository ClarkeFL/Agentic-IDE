import SwiftUI

@main
struct AgenticIDEApp: App {
    @State private var store = ProjectStore()
    @State private var sessions = SessionManager()
    @StateObject private var updater = UpdaterManager()

    init() {
        GhosttyApp.shared.bootstrap()
    }

    var body: some Scene {
        WindowGroup("Agentic IDE") {
            MainWindow()
                .environment(store)
                .environment(sessions)
                .environmentObject(updater)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Project…") {
                    NotificationCenter.default.post(name: .addProject, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            // Sparkle-driven update flow. Sits in the app menu where macOS
            // users expect it.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        // Standard macOS Settings… scene (gives ⌘, automatically).
        Settings {
            SettingsView()
        }
    }
}

extension Notification.Name {
    static let addProject = Notification.Name("AgenticIDE.addProject")
}
