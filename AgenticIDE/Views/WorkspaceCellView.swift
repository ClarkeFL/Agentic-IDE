import SwiftUI

/// One cell of a workspace grid. Either renders the cell's live terminal (with
/// a hover toolbar for zoom/close) or, when empty, the launcher. Owns building
/// the `TerminalTab` on launch since that needs the project + store; the
/// session just places the finished tab into the cell.
struct WorkspaceCellView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(LaunchToolStore.self) private var launchTools

    let project: Project
    @Bindable var session: ProjectSession
    @Bindable var workspace: Workspace
    @Bindable var cell: WorkspaceCell
    /// True when this cell is on screen (active workspace, not hidden by zoom).
    let isActive: Bool
    /// True when this cell is the one currently filling the workspace.
    let isZoomed: Bool

    @State private var hovering = false
    @State private var showServerPopover = false
    /// The Server tool the user clicked — captured so the deferred spawn (after
    /// the Run Server popover) launches it with the right icon.
    @State private var serverTool: LaunchTool?

    var body: some View {
        VStack(spacing: 0) {
            if let tab = cell.terminal {
                cellHeader(tab)
                Divider()
                GhosttyTerminal(view: tab.view,
                                isActive: isActive,
                                autoFocus: shouldAutoFocus,
                                onFocused: { workspace.focusedCellId = cell.id })
            } else {
                CellLauncherView(tools: launchTools.enabledTools, onLaunch: launch)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        // Seamless tile inside the workspace pane card — no rounded border of
        // its own. The inter-cell gap is the only rest-state separator; the
        // focused cell gets an accent edge so you can still see where keystrokes
        // land. Corner tiles are rounded by the pane card's own clip.
        .overlay(
            Rectangle()
                .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                .opacity(isFocused ? 1 : 0)
        )
        .onHover { hovering = $0 }
        .popover(isPresented: $showServerPopover, arrowEdge: .top) {
            RunServerPopover(
                initialCommand: serverQuickLaunch?.command ?? "",
                onSave: { cmd in
                    saveServerCommand(cmd)
                    showServerPopover = false
                    if let serverTool {
                        workspace.focusedCellId = cell.id
                        _ = launcher.launch(serverTool, into: cell)
                    }
                },
                onCancel: { showServerPopover = false })
        }
    }

    private var isFocused: Bool {
        workspace.focusedCellId == cell.id && cell.terminal != nil
    }

    // MARK: - Terminal

    /// Built-in title bar at the top of a running cell. Part of the layout (a
    /// VStack row), NOT an overlay — so it never hides terminal output. The
    /// terminal renders below it and fills the rest of the cell.
    private func cellHeader(_ tab: TerminalTab) -> some View {
        HStack(spacing: DS.Space.xs) {
            quickLaunchIcon(name: cell.icon, size: DS.FontSize.footnote)
            Text(tab.title)
                .font(DS.Font.control)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DS.Space.sm)
            ToolbarIconButton(
                systemName: "point.3.connected.trianglepath.dotted",
                help: cell.isOrchestrator
                    ? "Orchestrator — coordinates other cells. Click to stand down."
                    : "Make this cell the Orchestrator (drives the other cells)",
                isActive: cell.isOrchestrator) {
                    toggleOrchestrator(tab)
                }
            ToolbarIconButton(
                systemName: isZoomed
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                help: isZoomed ? "Restore grid (⌃⌘F)" : "Zoom cell (⌃⌘F)") {
                    session.toggleZoom(cellId: cell.id, in: workspace)
                }
            ToolbarIconButton(systemName: "xmark", help: "Close terminal") {
                session.closeCell(cell)
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .frame(height: DS.Control.standard)
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { workspace.focusedCellId = cell.id }
    }

    /// Only one cell should grab first responder on appear. Prefer the focused
    /// cell; otherwise the first running cell in the grid.
    private var shouldAutoFocus: Bool {
        if let f = workspace.focusedCellId { return f == cell.id }
        return workspace.runningCells.first?.id == cell.id
    }

    /// 1-based position of this cell in the grid, matching the numbering the
    /// agent bridge uses.
    private var cellNumber: Int {
        (workspace.cells.firstIndex(where: { $0.id == cell.id }) ?? 0) + 1
    }

    /// Promote/demote this cell as the workspace Orchestrator. Promoting a live
    /// agent also briefs it immediately (its launch-time system prompt is
    /// already fixed); the flag persists so a relaunch reuses the orchestrator
    /// system prompt.
    private func toggleOrchestrator(_ tab: TerminalTab) {
        cell.isOrchestrator.toggle()
        if cell.isOrchestrator {
            tab.view.sendInput(CellLauncher.orchestratorBriefing(cellNumber: cellNumber), submit: true)
        }
    }

    // MARK: - Launching

    private var launcher: CellLauncher {
        CellLauncher(project: project, session: session, workspace: workspace, store: store)
    }

    private func launch(_ tool: LaunchTool) {
        // Server with no command yet needs the popover to set one first.
        if tool.role == .server, (serverQuickLaunch?.command ?? "").isEmpty {
            serverTool = tool
            showServerPopover = true
            return
        }
        // Focus the new cell so the fresh terminal grabs first responder on
        // attach (shouldAutoFocus keys off focusedCellId) — otherwise keystrokes
        // keep landing in the previously selected cell.
        workspace.focusedCellId = cell.id
        _ = launcher.launch(tool, into: cell)
    }

    private func saveServerCommand(_ cmd: String) {
        guard var ql = serverQuickLaunch else { return }
        ql.command = cmd
        store.updateQuickLaunch(projectId: project.id, ql)
    }

    /// The project's saved Server launcher (carries its per-project command).
    private var serverQuickLaunch: QuickLaunch? {
        project.quickLaunches.first(where: { $0.label == "Run Server" })
    }
}

/// Small icon button used in the cell hover toolbar.
private struct ToolbarIconButton: View {
    let systemName: String
    let help: String
    /// Renders the button in a persistent "on" state (accent tint + fill).
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: DS.Icon.small, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .frame(width: DS.Control.compact, height: DS.Control.compact)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(Color.accentColor.opacity(isActive ? 0.18 : 0.0))
                )
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(Color.primary.opacity(isHovered && !isActive ? 0.12 : 0.0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
