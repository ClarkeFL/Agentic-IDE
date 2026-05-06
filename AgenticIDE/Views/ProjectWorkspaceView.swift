import SwiftUI

/// Middle pane: the tab bar + the active terminal (or the empty state).
struct ProjectWorkspaceView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @Environment(SystemSpeaker.self) private var speaker

    let project: Project

    var body: some View {
        let session = sessions.session(for: project.id)

        VStack(spacing: 0) {
            // TabBarView owns its own trailing divider so the three column
            // headers (sidebar, workspace, inspector) all draw their dividers
            // at the same y-coordinate.
            TabBarView(project: project,
                       onLaunch: { ql in launch(ql, in: session) },
                       onSaveQuickLaunch: { ql in saveQuickLaunch(ql) },
                       onLaunchDefaultShell: { launchDefaultShell(in: session) },
                       isSpeaking: speaker.isSpeaking,
                       onSpeakSelection: { speakSelection(in: session) })

            ZStack {
                // Keep every terminal NSView attached to the hierarchy at the
                // same time and just toggle activeness to switch. Adding/
                // removing surfaces from the AppKit tree on every switch was
                // the source of the visible lag — surfaces now stay live and
                // instantly pop to the front when their tab is selected.
                // `isActive` drives both the SwiftUI overlay (opacity / hit
                // test / z-order) and the AppKit-level hide signal (Ghostty
                // surface occlusion + metal layer isHidden) so background
                // tabs aren't burning GPU on frames the user can't see.
                ForEach(session.tabs) { tab in
                    let isActive = tab.id == session.activeTabId
                    GhosttyTerminal(view: tab.view, isActive: isActive)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .zIndex(isActive ? 1 : 0)
                }
                if session.activeTab == nil {
                    EmptyStateView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .onReceive(NotificationCenter.default.publisher(for: .speakSelection)) { _ in
            speakSelection(in: session)
        }
        .onChange(of: session.activeTabId) { _, _ in
            // Tab switch — stop any in-progress speech so we don't read
            // stale text aloud while the user is on a new terminal.
            speaker.stop()
        }
    }

    /// If something is already speaking, treat the button/hotkey as Stop.
    /// Otherwise read the active tab's selection (or fall back to the visible
    /// grid contents — see `readSpeakable`). No-op when nothing is selected
    /// and no project is active.
    private func speakSelection(in session: ProjectSession) {
        if speaker.isSpeaking { speaker.stop(); return }
        guard let tab = session.activeTab,
              let text = tab.view.readSelection() else { return }
        speaker.speak(text)
    }

    // MARK: - Launching

    private func launch(_ ql: QuickLaunch, in session: ProjectSession) {
        // Persist the (possibly updated) command back to the store.
        store.updateQuickLaunch(projectId: project.id, ql)
        guard !ql.command.isEmpty else { return }

        let cfg = PtyService.quickLaunchConfig(ql, cwd: project.path)
        let tab = TerminalTab(title: ql.label, config: cfg)
        session.wireSmartRename(tab)
        session.addTab(tab)
        store.recordActivity(projectId: project.id, command: ql.command)
    }

    private func saveQuickLaunch(_ ql: QuickLaunch) {
        store.updateQuickLaunch(projectId: project.id, ql)
    }

    private func launchDefaultShell(in session: ProjectSession) {
        let cfg = PtyService.defaultShellConfig(cwd: project.path)
        let shell = (PtyService.defaultShell() as NSString).lastPathComponent
        let tab = TerminalTab(title: shell, config: cfg)
        session.wireSmartRename(tab)
        session.addTab(tab)
        store.recordActivity(projectId: project.id, command: shell)
    }
}
