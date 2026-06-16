import Foundation

/// Builds and places a `TerminalTab` for a `LaunchTool` into a workspace cell.
/// Shared by the cell launcher UI (`WorkspaceCellView`) and the agent bridge
/// (`CellBus`) so both spawn tools identically — including the cell-bridge
/// system-prompt hint injected into agent CLIs in multi-cell workspaces.
struct CellLauncher {
    let project: Project
    let session: ProjectSession
    let workspace: Workspace
    let store: ProjectStore

    /// The project's per-project Run Server launcher.
    var serverQuickLaunch: QuickLaunch? {
        project.quickLaunches.first(where: { $0.label == "Run Server" })
    }

    /// Launch a tool into a cell, replacing whatever is there. Returns nil on
    /// success or a short error string (e.g. Server with no command set — the
    /// bridge can't prompt for one).
    @discardableResult
    func launch(_ tool: LaunchTool, into cell: WorkspaceCell) -> String? {
        switch tool.role {
        case .terminal:
            let cfg = PtyService.defaultShellConfig(cwd: project.path)
            let shell = (PtyService.defaultShell() as NSString).lastPathComponent
            place(TerminalTab(title: shell, config: cfg), tool: tool, in: cell, command: shell)
            return nil

        case .server:
            guard let ql = serverQuickLaunch, !ql.command.isEmpty else {
                return "Server has no command set for this project"
            }
            let cfg = PtyService.quickLaunchConfig(ql, cwd: project.path)
            place(TerminalTab(title: ql.label, config: cfg), tool: tool, in: cell, command: ql.command)
            return nil

        case .command:
            guard !tool.command.isEmpty else { return "\(tool.name) has no command" }
            let command = commandWithBridgeHint(tool, cell: cell)
            let ql = QuickLaunch(label: tool.name, command: command, icon: tool.icon)
            let cfg = PtyService.quickLaunchConfig(ql, cwd: project.path)
            place(TerminalTab(title: tool.name, config: cfg), tool: tool, in: cell, command: tool.command)
            return nil
        }
    }

    private func place(_ tab: TerminalTab, tool: LaunchTool, in cell: WorkspaceCell, command: String) {
        session.place(tab, icon: tool.icon, in: cell)
        store.recordActivity(projectId: project.id, command: command)
    }

    /// In a multi-cell workspace, append the bridge note to the agent's system
    /// prompt (for CLIs with an inline append flag), so it knows it can drive
    /// the other cells without having to discover the helper first.
    private func commandWithBridgeHint(_ tool: LaunchTool, cell: WorkspaceCell) -> String {
        guard workspace.cells.count > 1,
              let flag = tool.effectivePromptFlag, !flag.isEmpty else { return tool.command }
        let n = (workspace.cells.firstIndex(where: { $0.id == cell.id }) ?? 0) + 1
        // Single-quoted; the hint contains no apostrophes so it stays intact
        // after PtyService re-quotes the whole command for the login shell.
        return "\(tool.command) \(flag) '\(Self.bridgeHint(cellNumber: n))'"
    }

    /// The system-prompt note. No apostrophes — it is single-quoted in the shell
    /// command and PtyService escapes the surrounding quotes.
    static func bridgeHint(cellNumber n: Int) -> String {
        """
        You are running inside AgenticIDE as cell #\(n) in a workspace grid. \
        You can build out and orchestrate the other cells with the agentide CLI on your PATH: \
        `agentide cells` lists the cells (number, what is running, status); \
        `agentide tools` lists the launchers you can start (e.g. claude, codex); \
        `agentide grid <rows> <cols>` resizes the grid (max 2 rows by 4 cols) to make room; \
        `agentide launch <n> <tool>` starts a tool in cell n; \
        `agentide close <n>` closes the program in cell n; \
        `agentide send <n> "<text>"` types text and presses Enter in cell n (e.g. to give another agent a task); \
        `agentide read <n>` shows the screen of cell n so you can review its progress; \
        `agentide wait <n>` blocks until cell n finishes. \
        Use these when the user asks you to coordinate multiple agents or terminals.
        """
    }
}
