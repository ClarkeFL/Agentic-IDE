import Foundation

/// Runs a project's named servers into a dedicated "Servers" workspace, so they
/// don't take up cells in your working grid. You jump to them from the bottom
/// `ServerBar` (or the sidebar) — the same workspace switch used everywhere.
///
/// "Running" is tracked loosely: a server is running iff a live cell in the
/// Servers workspace carries its name as the terminal title. Matching by title
/// is enough here — server names are short and stable.
// ponytail: cell-present == running. If a server process dies the dead cell
// still reads as "running"; wire real process-exit detection only if it bites.
struct ServerRunner {
    let project: Project
    let session: ProjectSession
    let store: ProjectStore

    static let workspaceName = "Servers"
    private static var maxCells: Int { Workspace.maxCells }

    private var workspace: Workspace? {
        session.workspaces.first { $0.name == Self.workspaceName }
    }

    /// Names of servers currently live in the Servers workspace.
    func runningLabels() -> Set<String> {
        guard let ws = workspace else { return [] }
        return Set(ws.cells.compactMap { $0.terminal?.title })
    }

    /// Launch each given server that isn't already running into the Servers
    /// workspace (growing the grid to fit), then switch to it.
    func run(_ servers: [QuickLaunch]) {
        let toRun = servers.filter { !$0.command.isEmpty }
        guard !toRun.isEmpty else { return }

        let want = min(Self.maxCells,
                       runningLabels().union(toRun.map(\.label)).count)
        let ws = ensureWorkspace(forAtLeast: want)
        let live = runningLabels()

        for ql in toRun where !live.contains(ql.label) {
            guard let cell = ws.cells.first(where: { $0.terminal == nil }) else { break }
            let cfg = PtyService.quickLaunchConfig(ql, cwd: project.path)
            session.place(TerminalTab(title: ql.label, config: cfg),
                          icon: "play.circle", in: cell)
            store.recordActivity(projectId: project.id, command: ql.command)
        }
        session.activeWorkspaceId = ws.id
    }

    /// Switch to the Servers workspace and focus the cell running `label`.
    func jump(to label: String) {
        guard let ws = workspace else { return }
        session.activeWorkspaceId = ws.id
        if let cell = ws.cells.first(where: { $0.terminal?.title == label }) {
            ws.focusedCellId = cell.id
        }
    }

    /// Close every running server cell (the empty workspace is left in place).
    func stopAll() {
        guard let ws = workspace else { return }
        for cell in ws.cells where cell.terminal != nil { session.closeCell(cell) }
    }

    // MARK: - Helpers

    private func ensureWorkspace(forAtLeast n: Int) -> Workspace {
        let layout = GridLayout.fit(n)
        if let ws = workspace {
            if ws.cellCount < n { session.resizeWorkspace(ws, layout: layout) }
            return ws
        }
        let ws = session.addWorkspace(layout: layout)
        session.renameWorkspace(id: ws.id, to: Self.workspaceName)
        return ws
    }
}
