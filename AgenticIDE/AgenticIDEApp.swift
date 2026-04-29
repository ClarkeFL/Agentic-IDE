import AppKit
import SwiftUI

@main
struct AgenticIDEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ProjectStore()
    @State private var sessions = SessionManager()
    @State private var speaker = SystemSpeaker()
    @State private var resources = ResourceMonitor()
    @StateObject private var updater = UpdaterManager()

    init() {
        GhosttyApp.shared.bootstrap()
        // Touch the singleton from the main thread so its DispatchSource is
        // installed before the first terminal spawns. Lazy init from
        // TerminalTab.init would also work but might land on a non-main
        // queue depending on where the first tab is created.
        _ = AgentStatusWatcher.shared
    }

    var body: some Scene {
        WindowGroup("Agentic IDE") {
            MainWindow()
                .environment(store)
                .environment(sessions)
                .environment(speaker)
                .environment(resources)
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

/// Lives only to make termination unrefusable. macOS sends a quit AppleEvent
/// when the user toggles a TCC permission and clicks "Quit & Reopen" in
/// System Settings; with no override, that event was being silently refused
/// (audible system bell, no quit) whenever our FDA-onboarding sheet was up.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        dismissAttachedSheets(in: sender)
        return .terminateNow
    }

    @objc private func handleQuitAppleEvent(_ event: NSAppleEventDescriptor,
                                            withReplyEvent reply: NSAppleEventDescriptor) {
        // Tell the sender (System Settings, in the "Quit & Reopen" flow) we
        // accepted the quit cleanly. Without an explicit noErr in the reply,
        // System Settings has been observed to roll back the TCC toggle that
        // triggered the event — the user grants Full Disk Access, clicks
        // Quit & Reopen, the app cycles, and the toggle is back to off.
        // 'errn' = keyErrorNumber from <Carbon/AECoreSuite.h>.
        let keyErrn: AEKeyword = 0x6572_726E
        reply.setDescriptor(NSAppleEventDescriptor(int32: 0), forKeyword: keyErrn)

        dismissAttachedSheets(in: NSApp)
        // Defer terminate to the next runloop turn so the AppleEvent
        // dispatcher has a chance to send the reply we just filled in
        // *before* we begin tearing the process down.
        DispatchQueue.main.async { NSApp.terminate(nil) }
        // Background queue: a mid-termination main runloop can stall main-queue
        // dispatches and skip our safety-net exit, leaving the old process
        // alongside the relaunched one.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.6) {
            exit(0)
        }
    }

    private func dismissAttachedSheets(in app: NSApplication) {
        for window in app.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
    }
}
