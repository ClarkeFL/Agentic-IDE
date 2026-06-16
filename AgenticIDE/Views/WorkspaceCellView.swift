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
    /// Icon of the Server tool the user clicked — captured so the deferred
    /// spawn (after the Run Server popover) tags the cell with the right glyph.
    @State private var serverIcon: String = "play.circle"

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
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isFocused ? 1.5 : 1)
        )
        .onHover { hovering = $0 }
        .popover(isPresented: $showServerPopover, arrowEdge: .top) {
            RunServerPopover(
                initialCommand: serverQuickLaunch?.command ?? "",
                onSave: { cmd in
                    saveServerCommand(cmd)
                    showServerPopover = false
                    spawnServer()
                },
                onCancel: { showServerPopover = false })
        }
    }

    private var isFocused: Bool {
        workspace.focusedCellId == cell.id && cell.terminal != nil
    }

    private var borderColor: Color {
        isFocused ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor)
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

    // MARK: - Launching

    private func launch(_ tool: LaunchTool) {
        switch tool.role {
        case .server:
            serverIcon = tool.icon
            if (serverQuickLaunch?.command ?? "").isEmpty {
                showServerPopover = true
            } else {
                spawnServer()
            }
        case .terminal:
            spawnShell(icon: tool.icon)
        case .command:
            spawnCommand(tool)
        }
    }

    /// Runs the project's per-project Run Server command.
    private func spawnServer() {
        guard let ql = serverQuickLaunch, !ql.command.isEmpty else { return }
        let cfg = PtyService.quickLaunchConfig(ql, cwd: project.path)
        let tab = TerminalTab(title: ql.label, config: cfg)
        session.place(tab, icon: serverIcon, in: cell)
        store.recordActivity(projectId: project.id, command: ql.command)
    }

    /// Runs a `.command` tool's command via the login shell. The Claude/Codex
    /// "dangerous" flags still apply because `quickLaunchConfig` augments by
    /// executable name.
    private func spawnCommand(_ tool: LaunchTool) {
        guard !tool.command.isEmpty else { return }
        let ql = QuickLaunch(label: tool.name, command: tool.command, icon: tool.icon)
        let cfg = PtyService.quickLaunchConfig(ql, cwd: project.path)
        let tab = TerminalTab(title: tool.name, config: cfg)
        session.place(tab, icon: tool.icon, in: cell)
        store.recordActivity(projectId: project.id, command: tool.command)
    }

    private func spawnShell(icon: String) {
        let cfg = PtyService.defaultShellConfig(cwd: project.path)
        let shell = (PtyService.defaultShell() as NSString).lastPathComponent
        let tab = TerminalTab(title: shell, config: cfg)
        session.place(tab, icon: icon, in: cell)
        store.recordActivity(projectId: project.id, command: shell)
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
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: DS.Icon.small, weight: .semibold))
                .frame(width: DS.Control.compact, height: DS.Control.compact)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.12 : 0.0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
