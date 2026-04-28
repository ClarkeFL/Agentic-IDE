import SwiftUI

@main
struct AgenticIDEApp: App {
    @State private var store = ProjectStore()
    @State private var sessions = SessionManager()
    @State private var speaker = SystemSpeaker()
    @StateObject private var updater = UpdaterManager()

    init() {
        GhosttyApp.shared.bootstrap()
    }

    var body: some Scene {
        WindowGroup("Agentic IDE") {
            MainWindow()
                .environment(store)
                .environment(sessions)
                .environment(speaker)
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
            // Speak selection from the active terminal. ProjectWorkspaceView
            // observes the notification and calls into its active tab.
            CommandMenu("Speech") {
                Button("Speak Selection") {
                    NotificationCenter.default.post(name: .speakSelection, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Stop Speaking") { speaker.stop() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .disabled(!speaker.isSpeaking)
            }
            // Sparkle-driven update flow. Sits in the app menu where macOS
            // users expect it.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        // Standard macOS Settings… scene (gives ⌘, automatically). The
        // Speech tab uses the shared SystemSpeaker for the Preview button.
        Settings {
            SettingsView()
                .environment(speaker)
        }
    }
}

extension Notification.Name {
    static let addProject = Notification.Name("AgenticIDE.addProject")
    /// Posted by the Speech menu command. Observed by `ProjectWorkspaceView`,
    /// which forwards the active tab's selected text to the shared `Speaker`.
    static let speakSelection = Notification.Name("AgenticIDE.speakSelection")
}
