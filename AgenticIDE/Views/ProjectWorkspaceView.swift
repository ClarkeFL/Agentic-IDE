import SwiftUI

/// Pane ④: the active workspace's header + grid (or an empty state while a
/// project's session is still restoring).
struct ProjectWorkspaceView: View {
    @Environment(SessionManager.self) private var sessions
    @Environment(SystemSpeaker.self) private var speaker

    let project: Project

    var body: some View {
        let session = sessions.session(for: project.id)

        VStack(spacing: 0) {
            if let workspace = session.activeWorkspace {
                WorkspaceHeaderView(session: session,
                                    workspace: workspace,
                                    isSpeaking: speaker.isSpeaking,
                                    onSpeak: { speakSelection(in: session) })
                WorkspaceGridView(project: project, session: session, workspace: workspace)
            } else {
                EmptyStateView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .speakSelection)) { _ in
            speakSelection(in: session)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCellZoom)) { _ in
            toggleZoomFocused(in: session)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newWorkspace)) { _ in
            session.addWorkspace()
        }
        .onChange(of: session.activeWorkspaceId) { _, _ in
            // Workspace switch — stop any in-progress speech so we don't read
            // stale text aloud while the user is on a new workspace.
            speaker.stop()
        }
    }

    /// If something is already speaking, treat the button/hotkey as Stop.
    /// Otherwise read the focused cell's selection (falling back to the first
    /// running cell).
    private func speakSelection(in session: ProjectSession) {
        if speaker.isSpeaking { speaker.stop(); return }
        guard let ws = session.activeWorkspace else { return }
        let cell = ws.cells.first(where: { $0.id == ws.focusedCellId }) ?? ws.runningCells.first
        guard let tab = cell?.terminal, let text = tab.view.readSelection() else { return }
        speaker.speak(text)
    }

    /// Zoom the focused cell (falling back to the already-zoomed cell, then the
    /// first running cell, then the first cell). Re-firing restores the grid.
    private func toggleZoomFocused(in session: ProjectSession) {
        guard let ws = session.activeWorkspace else { return }
        let target = ws.focusedCellId
            ?? ws.zoomedCellId
            ?? ws.runningCells.first?.id
            ?? ws.cells.first?.id
        guard let id = target else { return }
        session.toggleZoom(cellId: id, in: ws)
    }
}
