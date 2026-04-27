import SwiftUI

/// Middle pane: the tab bar + the active terminal (or the empty state).
struct ProjectWorkspaceView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionManager.self) private var sessions

    let project: Project

    var body: some View {
        let session = sessions.session(for: project.id)

        VStack(spacing: 0) {
            TabBarView(project: project,
                       onLaunch: { ql in launch(ql, in: session) },
                       onLaunchDefaultShell: { launchDefaultShell(in: session) })

            Divider()

            ZStack {
                // Keep every terminal NSView attached to the hierarchy at the
                // same time and just toggle opacity to switch. Adding/removing
                // surfaces from the AppKit tree on every switch was the source
                // of the visible lag — surfaces now stay live and instantly
                // pop to the front when their tab is selected.
                ForEach(session.tabs) { tab in
                    GhosttyTerminal(view: tab.view)
                        .opacity(tab.id == session.activeTabId ? 1 : 0)
                        .allowsHitTesting(tab.id == session.activeTabId)
                        .zIndex(tab.id == session.activeTabId ? 1 : 0)
                }
                if session.activeTab == nil {
                    EmptyStateView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
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

    private func launchDefaultShell(in session: ProjectSession) {
        let cfg = PtyService.defaultShellConfig(cwd: project.path)
        let shell = (PtyService.defaultShell() as NSString).lastPathComponent
        let tab = TerminalTab(title: shell, config: cfg)
        session.wireSmartRename(tab)
        session.addTab(tab)
        store.recordActivity(projectId: project.id, command: shell)
    }
}
