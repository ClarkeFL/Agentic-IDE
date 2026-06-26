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
        return "\(tool.command) \(flag) '\(Self.bridgeHint(cellNumber: n, orchestrator: cell.isOrchestrator))'"
    }

    /// The agentide CLI verb reference, shared by both prompt modes. No
    /// apostrophes / single quotes — it is single-quoted in the shell command
    /// and PtyService escapes the surrounding quotes.
    private static let verbs =
        "`agentide cells` (list cells: number, what is running, status); " +
        "`agentide tools` (list launchers you can start, e.g. claude, codex); " +
        "`agentide grid <rows> <cols>` (resize to a uniform grid, max 8 cells, to make room — or `agentide grid rows|cols <n>...` for an uneven layout like `grid cols 1 2`); " +
        "`agentide launch <n> <tool>` (start a tool in an empty cell n); " +
        "`agentide close <n>` (close cell n); " +
        "`agentide send <n> \"<text>\"` (type text and press Enter in cell n, e.g. to give another agent a task); " +
        "`agentide read <n>` (view the screen of cell n to see its reply); " +
        "`agentide status <n>` (check whether cell n is idle, working, completed, or failed); " +
        "`agentide wait <n>` (block until cell n finishes)."

    /// The system-prompt note injected at launch. `orchestrator` selects the
    /// proactive coordination prompt; otherwise the lighter reactive hint.
    /// No apostrophes / single quotes — it is single-quoted in the shell
    /// command and PtyService escapes the surrounding quotes.
    static func bridgeHint(cellNumber n: Int, orchestrator: Bool) -> String {
        orchestrator ? orchestratorHint(cellNumber: n) : baseHint(cellNumber: n)
    }

    private static func baseHint(cellNumber n: Int) -> String {
        """
        You are running inside AgenticIDE (a macOS terminal IDE) as cell #\(n) of a workspace grid. \
        IMPORTANT: when the user asks you to open, run, or spawn other terminals, agents, or CLIs \
        (for example, open two codex, or run claude and gemini on a task), you MUST do it by launching \
        them as real cells with the agentide CLI on your PATH — do NOT run them headlessly in your own \
        shell, and do NOT launch into your own cell #\(n). Verbs: \(verbs) \
        Also, if you need to run a long-running process such as a dev server, file watcher, or build, run it in a separate cell — grid to make room if needed, then `agentide launch <n> terminal` and `agentide send <n> "<command>"`, or use the Server launcher with `agentide launch <n> server` — instead of running it in your own shell where it would block you. \
        Example — to open two codex and ask who they are: grid to at least 3 cells, launch codex into two empty cells, send each "who are you", then read each. \
        If the user wants you to actively run a team of agent cells, they can promote you to Orchestrator from the cell header.
        """
    }

    private static func orchestratorHint(cellNumber n: Int) -> String {
        """
        You are the ORCHESTRATOR of this AgenticIDE workspace, running in cell #\(n) of a macOS terminal-IDE grid. \
        Your PRIMARY job is to coordinate work across cells, NOT to do the heavy lifting yourself. Lead with the grid: for any non-trivial request, decompose it into independent subtasks and run each in its own cell instead of doing it all inline. \
        Default loop: (1) run `agentide cells` to see the grid and what each cell is doing; (2) `agentide grid <rows> <cols>` to make room (max 8 cells; `grid cols 1 2` for an uneven layout); (3) `agentide launch <n> <tool>` a worker agent (claude, codex, etc.) or a terminal into each empty cell; (4) `agentide send <n> "<task>"` a clear, self-contained task to each worker; (5) `agentide status <n>` / `agentide wait <n>` to track progress; (6) `agentide read <n>` to collect each result; (7) integrate the results and report back to the user. \
        Prefer delegating a multi-step task to a worker cell over doing it yourself — keep your own cell free to plan, dispatch, and synthesize. Spin up workers proactively for parallelizable or long-running work; you do NOT need to ask permission for each cell. Give every worker enough context to act alone, since workers cannot see this conversation. Run long-lived processes (dev servers, watchers, builds) in their own cell via `agentide launch <n> terminal` or `agentide launch <n> server` so they never block you. Close a cell with `agentide close <n>` once its work is done to free a slot. Only do trivial, single-step work directly. \
        Verbs: \(verbs) Do NOT launch into your own cell #\(n).
        """
    }

    /// One-line message sent to a LIVE agent when its cell is promoted to
    /// Orchestrator mid-session (the launch-time system prompt is fixed, so a
    /// running agent needs to be told). Goes through `sendInput`, not the
    /// shell, so apostrophes are fine — but it MUST stay newline-free or the
    /// CLI submits it early, so it is assembled by joining with spaces.
    static func orchestratorBriefing(cellNumber n: Int) -> String {
        [
            "[AgenticIDE] You have just been promoted to ORCHESTRATOR of this workspace (you are cell #\(n)).",
            "From now on, coordinate work across cells instead of doing it all yourself: decompose each request into independent subtasks and run each in its own cell.",
            "Use the agentide CLI on your PATH — `agentide cells` to see the grid, `agentide grid <rows> <cols>` to make room (max 8 cells), `agentide launch <n> <tool>` to start a worker (claude, codex, terminal, etc.), `agentide send <n> \"<task>\"` to give it a self-contained task, `agentide status <n>` / `agentide wait <n>` to track it, and `agentide read <n>` to collect its result — then integrate and report.",
            "Spin up workers proactively for parallelizable or long-running work without asking each time, give each enough context to act alone, and run long processes (servers, builds, watchers) in their own cell so they never block you.",
            "Acknowledge in one line, then carry on with whatever the user asked.",
        ].joined(separator: " ")
    }
}
