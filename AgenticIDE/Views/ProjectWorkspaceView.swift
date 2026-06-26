import SwiftUI

/// Pane ④: the active workspace's header + grid. When a project has no
/// workspace yet (or the user asks for a new one), it shows the layout chooser
/// instead — a workspace is only created once a grid size is picked.
struct ProjectWorkspaceView: View {
    @Environment(SessionManager.self) private var sessions
    @Environment(SystemSpeaker.self) private var speaker

    let project: Project
    /// Trailing margin of the pane card. `DS.Space.md` when this is the
    /// rightmost pane (window edge); `0` when the Notes pane sits to its right,
    /// so the divider zone alone supplies the gap (matching the other seams).
    var trailingInset: CGFloat = DS.Space.md

    /// Set when the user asks for a new workspace (sidebar +, ⌘T) so the
    /// chooser shows even if there's already an active workspace.
    @State private var showLayoutChooser = false

    var body: some View {
        let session = sessions.session(for: project.id)

        VStack(spacing: 0) {
            if showLayoutChooser || session.activeWorkspace == nil {
                LayoutChooserView(
                    canCancel: session.activeWorkspace != nil,
                    onSelect: { layout in
                        session.addWorkspace(layout: layout)
                        showLayoutChooser = false
                    },
                    onCancel: { showLayoutChooser = false })
            } else if let workspace = session.activeWorkspace {
                WorkspaceHeaderView(session: session,
                                    workspace: workspace,
                                    isSpeaking: speaker.isSpeaking,
                                    onSpeak: { speakSelection(in: session) })
                // Header sits inside the rounded card now, so a hairline rule
                // separates it from the cell grid below (the cells lost their
                // own borders to become seamless tiles).
                Divider()
                WorkspaceGridView(project: project, session: session, workspace: workspace)
                Divider()
                ServerBar(project: project, session: session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Same floating-card chrome as the explorer + sidebar panes. Flush (0)
        // against the divider on its leading side; the trailing margin is the
        // window edge (or 0 when the Notes pane is open to its right).
        .paneCard(fill: Color(nsColor: .controlBackgroundColor),
                  insets: EdgeInsets(top: DS.Space.xs, leading: 0,
                                     bottom: DS.Space.md, trailing: trailingInset))
        .onReceive(NotificationCenter.default.publisher(for: .speakSelection)) { _ in
            speakSelection(in: session)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCellZoom)) { _ in
            toggleZoomFocused(in: session)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newWorkspace)) { _ in
            // Already have a workspace → create + switch immediately (1×1) so it
            // shows in the sidebar right away; resize from the header grid
            // picker. The chooser is only for the empty-project first workspace,
            // where pane ④ has nothing else to show.
            if session.activeWorkspace == nil {
                showLayoutChooser = true
            } else {
                session.addWorkspace()
            }
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
    let onSelect: (GridLayout) -> Void
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

            GridLayoutPicker(current: nil, onSelect: onSelect)
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
        // controlBackgroundColor (not windowBackgroundColor) so the canvas
        // matches the rest of the app and renders identically whether the
        // window is active or not — windowBackgroundColor is wallpaper-tinted
        // only for the active app, which made this pane look lighter/"off" on
        // the inactive (e.g. release) window.
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
