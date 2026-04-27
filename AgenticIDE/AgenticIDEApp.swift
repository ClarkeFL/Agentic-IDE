import SwiftUI

@main
struct AgenticIDEApp: App {
    @State private var store = ProjectStore()
    @State private var sessions = SessionManager()

    init() {
        GhosttyApp.shared.bootstrap()
    }

    var body: some Scene {
        WindowGroup("Agentic IDE") {
            MainWindow()
                .environment(store)
                .environment(sessions)
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
        }
    }
}

extension Notification.Name {
    static let addProject = Notification.Name("AgenticIDE.addProject")
}
