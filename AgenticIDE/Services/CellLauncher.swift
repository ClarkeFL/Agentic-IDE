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

    /// Append the bridge note to the agent's system prompt (for CLIs with an
    /// inline append flag) so it knows it can build out and drive the workspace
    /// without having to discover the helper first. Injected even in a 1×1 — a
    /// solo agent is the common starting point for "open more cells".
    private func commandWithBridgeHint(_ tool: LaunchTool, cell: WorkspaceCell) -> String {
        guard let flag = tool.effectivePromptFlag, !flag.isEmpty else { return tool.command }
        let n = (workspace.cells.firstIndex(where: { $0.id == cell.id }) ?? 0) + 1
        // Single-quoted; the hint contains no apostrophes so it stays intact
        // after PtyService re-quotes the whole command for the login shell.
        return "\(tool.command) \(flag) '\(Self.bridgeHint(cellNumber: n))'"
    }

    /// The system-prompt note. No apostrophes / single quotes — it is
    /// single-quoted in the shell command and PtyService escapes the
    /// surrounding quotes.
    static func bridgeHint(cellNumber n: Int) -> String {
        """
        You are running inside AgenticIDE (a macOS terminal IDE) as cell #\(n) of a workspace grid. \
        IMPORTANT: when the user asks you to open, run, or spawn other terminals, agents, or CLIs \
        (for example, open two codex, or run claude and gemini on a task), you MUST do it by launching \
        them as real cells with the agentide CLI on your PATH — do NOT run them headlessly in your own \
        shell, and do NOT launch into your own cell #\(n). Verbs: \
        `agentide cells` (list cells: number, what is running, status); \
        `agentide tools` (list launchers you can start, e.g. claude, codex); \
        `agentide grid <rows> <cols>` (resize the grid, max 2 by 4, to make room for more cells); \
        `agentide launch <n> <tool>` (start a tool in an empty cell n); \
        `agentide close <n>` (close cell n); \
        `agentide send <n> "<text>"` (type text and press Enter in cell n, e.g. to ask another agent a question or give it a task); \
        `agentide read <n>` (view the screen of cell n to see its reply); \
        `agentide wait <n>` (block until cell n finishes). \
        Also, if you need to run a long-running process such as a dev server, file watcher, or build, run it in a separate cell — grid to make room if needed, then `agentide launch <n> terminal` and `agentide send <n> "<command>"`, or use the Server launcher with `agentide launch <n> server` — instead of running it in your own shell where it would block you. \
        Example — to open two codex and ask who they are: grid to at least 3 cells, launch codex into two empty cells, send each "who are you", then read each.
        """
    }
}
