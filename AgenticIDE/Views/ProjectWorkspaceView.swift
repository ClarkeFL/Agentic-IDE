import AppKit
import SwiftUI

/// Pane ④: the active workspace's header + grid. When a project has no
/// workspace yet (or the user asks for a new one), it shows the layout chooser
/// instead — a workspace is only created once a grid size is picked.
struct ProjectWorkspaceView: View {
    @Environment(SessionManager.self) private var sessions

    let project: Project
    /// Trailing margin of the pane card. `DS.Space.md` when this is the
    /// rightmost pane (window edge); `0` when the Notes pane sits to its right,
    /// so the divider zone alone supplies the gap (matching the other seams).
    var trailingInset: CGFloat = DS.Space.md

    /// Set when the user asks for a new workspace (sidebar +, ⌘T) so the
    /// chooser shows even if there's already an active workspace.
    @State private var showLayoutChooser = false
    @State private var swipeDirection = 1

    var body: some View {
        let session = sessions.session(for: project.id)

        VStack(spacing: 0) {
            ZStack {
                if showLayoutChooser || session.activeWorkspace == nil {
                    LayoutChooserView(
                        canCancel: session.activeWorkspace != nil,
                        onSelect: { layout in
                            session.addWorkspace(layout: layout)
                            showLayoutChooser = false
                        },
                        onCancel: { showLayoutChooser = false })
                } else if let workspace = session.activeWorkspace {
                    VStack(spacing: 0) {
                        WorkspaceHeaderView(session: session,
                                            workspace: workspace)
                        // Header sits inside the rounded card now, so a hairline rule
                        // separates it from the cell grid below (the cells lost their
                        // own borders to become seamless tiles).
                        Divider()
                        WorkspaceGridView(project: project, session: session, workspace: workspace)
                    }
                    .id(workspace.id)
                    .transition(workspaceTransition)
                }
            }
            .clipped()
            Divider()
            ServerBar(project: project, session: session)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            WorkspaceSwipeMonitor { direction in
                swipeDirection = direction
                withAnimation(.easeInOut(duration: 0.22)) {
                    session.moveWorkspace(by: direction)
                }
            }
        }
        // Same floating-card chrome as the explorer + sidebar panes. Flush (0)
        // against the divider on its leading side; the trailing margin is the
        // window edge (or 0 when the Notes pane is open to its right).
        .paneCard(fill: Color(nsColor: .controlBackgroundColor),
                  insets: EdgeInsets(top: DS.Space.xs, leading: 0,
                                     bottom: DS.Space.md, trailing: trailingInset))
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

    private var workspaceTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: swipeDirection > 0 ? .trailing : .leading),
            removal: .move(edge: swipeDirection > 0 ? .leading : .trailing)
        )
    }
}

/// Listens for AppKit's page-swipe event without adding a drag gesture that
/// would interfere with selecting text inside terminal cells.
private struct WorkspaceSwipeMonitor: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> WorkspaceSwipeNSView {
        let view = WorkspaceSwipeNSView()
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ nsView: WorkspaceSwipeNSView, context: Context) {
        nsView.onSwipe = onSwipe
    }
}

private final class WorkspaceSwipeNSView: NSView {
    var onSwipe: ((Int) -> Void)?
    private var eventMonitor: Any?

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeEventMonitor()
        guard window != nil else { return }

        // ponytail: .swipe only — never intercept scrollWheel, that ate
        // terminal scrolling. Requires System Settings › Trackpad › More
        // Gestures › "Swipe between pages" to include swiping; macOS owns
        // three-finger swipes otherwise.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] event in
            guard let self, let window,
                  event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  abs(event.deltaX) > abs(event.deltaY),
                  abs(event.deltaX) > 0 else { return event }
            onSwipe?(event.deltaX < 0 ? 1 : -1)
            return nil
        }
    }

    deinit {
        removeEventMonitor()
    }

    private func removeEventMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
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
