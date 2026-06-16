import SwiftUI

/// Pane ④: the active workspace's header + grid. When a project has no
/// workspace yet (or the user asks for a new one), it shows the layout chooser
/// instead — a workspace is only created once a grid size is picked.
struct ProjectWorkspaceView: View {
    @Environment(SessionManager.self) private var sessions
    @Environment(SystemSpeaker.self) private var speaker

    let project: Project

    /// Set when the user asks for a new workspace (sidebar +, ⌘T) so the
    /// chooser shows even if there's already an active workspace.
    @State private var showLayoutChooser = false

    var body: some View {
        let session = sessions.session(for: project.id)

        VStack(spacing: 0) {
            if showLayoutChooser || session.activeWorkspace == nil {
                LayoutChooserView(
                    canCancel: session.activeWorkspace != nil,
                    onSelect: { rows, cols in
                        session.addWorkspace(rows: rows, cols: cols)
                        showLayoutChooser = false
                    },
                    onCancel: { showLayoutChooser = false })
            } else if let workspace = session.activeWorkspace {
                WorkspaceHeaderView(session: session,
                                    workspace: workspace,
                                    isSpeaking: speaker.isSpeaking,
                                    onSpeak: { speakSelection(in: session) })
                WorkspaceGridView(project: project, session: session, workspace: workspace)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .speakSelection)) { _ in
            speakSelection(in: session)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCellZoom)) { _ in
            toggleZoomFocused(in: session)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newWorkspace)) { _ in
            showLayoutChooser = true
        }
        .onChange(of: project.id) { _, _ in
            // Different project — drop any transient chooser state.
            showLayoutChooser = false
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

/// Centered layout chooser shown before a workspace exists (or when adding a
/// new one). Picking a size is what actually creates the workspace.
private struct LayoutChooserView: View {
    let canCancel: Bool
    let onSelect: (Int, Int) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: DS.Space.lg) {
            VStack(spacing: DS.Space.xs) {
                Text("Choose a layout")
                    .font(.title3.weight(.semibold))
                Text("Pick how many cells this workspace has.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GridSizePicker(current: (1, 1), dotW: 46, dotH: 34, onSelect: onSelect)
                .padding(DS.Space.md)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

            if canCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.xxl)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
