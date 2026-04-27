import SwiftUI

/// Middle pane: the tab bar + the active terminal (or the empty state).
struct ProjectWorkspaceView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionManager.self) private var sessions

    let project: Project

    var body: some View {
        let session = sessions.session(for: project.id)

        VStack(spacing: 0) {
            TabBarView(session: session,
                       project: project,
                       onLaunch: { ql in launch(ql, in: session) },
                       onLaunchDefaultShell: { launchDefaultShell(in: session) },
                       onCloseTab: { id in session.closeTab(id: id) },
                       onSelectTab: { id in session.activeTabId = id })

            Divider()

            ZStack {
                if let active = session.activeTab {
                    GhosttyTerminal(view: active.view)
                        .id(active.id)
                } else {
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
        session.addTab(tab)
        store.recordActivity(projectId: project.id, command: ql.command)
    }

    private func launchDefaultShell(in session: ProjectSession) {
        let cfg = PtyService.defaultShellConfig(cwd: project.path)
        let shell = (PtyService.defaultShell() as NSString).lastPathComponent
        let tab = TerminalTab(title: shell, config: cfg)
        session.addTab(tab)
        store.recordActivity(projectId: project.id, command: shell)
    }
}
