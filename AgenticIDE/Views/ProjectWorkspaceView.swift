import AppKit
import SwiftUI

/// Pane ④: the active workspace's header + grid. When a project has no
/// workspace yet (or the user asks for a new one), it shows the layout chooser
/// instead — a workspace is only created once a grid size is picked.
struct ProjectWorkspaceView: View {
    @Environment(SessionManager.self) private var sessions

    let project: Project

    /// Set when the user asks for a new workspace (sidebar +, ⌘T) so the
    /// chooser shows even if there's already an active workspace.
    @State private var showLayoutChooser = false
    @State private var swipeDirection = 1

    /// Cold-launch only: auto-enter browser at most once per process so
    /// later project clicks never yank the user out of the grid.
    private static var didAutoRestoreBrowser = false

    var body: some View {
        let session = sessions.session(for: project.id)

        VStack(spacing: 0) {
            ZStack {
                if showLayoutChooser || session.activeWorkspace == nil {
                    LayoutChooserView(
                        canCancel: session.activeWorkspace != nil,
                        onSelectLayout: { layout in
                            session.addWorkspace(layout: layout)
                            showLayoutChooser = false
                        },
                        onSelectBrowser: {
                            // 1×1 grid underneath so the workspace exists in
                            // the pager; browser mode opens immediately.
                            let ws = session.addWorkspace(
                                layout: GridLayout(axis: .rows, counts: [1]))
                            BrowserManager.shared.openManual(from: ws,
                                                             projectSession: session)
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
        // The window's hidden-titlebar safe area still propagates into the
        // panes even though MainWindow ignores it; safe-area-aware descendants
        // (the cells' LazyVGrid launchers) then shrink away from the pane top
        // and paint over the header. Zero it out for the whole subtree here.
        .ignoresSafeArea(.container, edges: .top)
        .background {
            WorkspaceSwipeMonitor { direction in
                slide(direction, in: session)
            }
        }
        .background(DS.Surface.app)
        // Explicit hairline on the leading edge so the workspace always has a
        // visible left border, whatever pane (explorer, rail) sits beside it.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCellZoom)) { _ in
            toggleZoomFocused(in: session)
        }
        .onReceive(NotificationCenter.default.publisher(for: .moveWorkspace)) { note in
            guard let direction = note.object as? Int else { return }
            slide(direction, in: session)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newWorkspace)) { _ in
            // Offer layout presets + browser so a browser workspace is one click.
            showLayoutChooser = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceSessionRestored)) { note in
            // Cold launch only for the first restored project this process.
            // Project switches and workspace swipes never auto-enter browser —
            // the user opens it via globe / hover drawer / ⌘B.
            guard (note.object as? UUID) == project.id else { return }
            guard !Self.didAutoRestoreBrowser else { return }
            Self.didAutoRestoreBrowser = true
            restoreBrowserIfPreferred(for: session)
        }
        .onChange(of: project.id) { _, _ in
            // Different project — drop any transient chooser state.
            showLayoutChooser = false
        }
    }

    /// App launch only: re-open browser mode if the restored active workspace
    /// was a browser workspace last time. Never called on project/workspace switch.
    private func restoreBrowserIfPreferred(for session: ProjectSession) {
        guard let ws = session.activeWorkspace, ws.prefersBrowserMode else { return }
        BrowserManager.shared.openManual(from: ws, projectSession: session)
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

    private func slide(_ direction: Int, in session: ProjectSession) {
        swipeDirection = direction
        withAnimation(.easeInOut(duration: 0.22)) {
            session.moveWorkspace(by: direction)
        }
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

/// Centered chooser shown before a workspace exists (or when adding a new
/// one). Step 1: **Grid** vs **Browser**. Step 2 (Grid only): the four daily
/// layout shapes. Full layout palette stays on the header once a workspace
/// is open.
private struct LayoutChooserView: View {
    let canCancel: Bool
    let onSelectLayout: (GridLayout) -> Void
    let onSelectBrowser: () -> Void
    let onCancel: () -> Void

    /// After tapping Grid, show the four layout presets instead of the mode pair.
    @State private var pickingGridLayout = false

    var body: some View {
        VStack(spacing: DS.Space.lg) {
            if pickingGridLayout {
                gridLayoutStep
            } else {
                modeStep
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.xxl)
        // controlBackgroundColor (not windowBackgroundColor) so the canvas
        // matches the rest of the app and renders identically whether the
        // window is active or not — windowBackgroundColor is wallpaper-tinted
        // only for the active app, which made this pane look lighter/"off" on
        // the inactive (e.g. release) window.
        .background(DS.Surface.app)
    }

    /// Step 1 — Grid or Browser.
    private var modeStep: some View {
        VStack(spacing: DS.Space.lg) {
            VStack(spacing: DS.Space.xs) {
                Text("New workspace")
                    .font(.title3.weight(.semibold))
                Text("Agent cells in a grid, or a browser for servers and preview.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: DS.Space.md) {
                modeCard(title: "Grid",
                         subtitle: "Agent cells",
                         systemImage: "square.grid.2x2",
                         action: { pickingGridLayout = true })
                modeCard(title: "Browser",
                         subtitle: "Servers + preview",
                         systemImage: "globe",
                         action: onSelectBrowser)
            }

            if canCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Step 2 — four quick layouts after Grid is chosen.
    private var gridLayoutStep: some View {
        VStack(spacing: DS.Space.lg) {
            VStack(spacing: DS.Space.xs) {
                Text("Choose a layout")
                    .font(.title3.weight(.semibold))
                Text("More shapes anytime from the header once you're in.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: DS.Space.sm) {
                ForEach(Array(GridLayout.quickPresets.enumerated()), id: \.offset) { _, preset in
                    layoutCard(preset)
                }
            }

            Button("Back") { pickingGridLayout = false }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func layoutCard(_ preset: (title: String, layout: GridLayout)) -> some View {
        Button { onSelectLayout(preset.layout) } label: {
            VStack(spacing: DS.Space.md) {
                LayoutGlyph(layout: preset.layout, square: 14, gap: 4) { _, _ in
                    Color.accentColor.opacity(0.85)
                }
                .frame(height: 40)
                Text(preset.title)
                    .font(DS.Font.bodySemibold)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 110, height: 130)
            .padding(.horizontal, DS.Space.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(preset.title)
    }

    private func modeCard(title: String, subtitle: String,
                          systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: DS.Space.md) {
                Image(systemName: systemImage)
                    .font(.system(size: DS.Icon.display, weight: .light))
                    .foregroundStyle(Color.accentColor)
                VStack(spacing: DS.Space.xs) {
                    Text(title)
                        .font(DS.Font.bodySemibold)
                    Text(subtitle)
                        .font(DS.Font.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 140)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
