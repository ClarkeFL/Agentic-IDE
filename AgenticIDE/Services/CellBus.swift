import Foundation

/// Resolves agent-bridge requests against the live workspace grid: lists the
/// caller's sibling cells, reads a cell's screen, sends input to a cell, or
/// reports a cell's status. A caller can only reach cells in its own workspace
/// (resolved from its surface id), so an orchestrator agent can't reach across
/// projects. All methods touch Ghostty surfaces, so they must run on the main
/// thread — `AgentBridgeServer` dispatches them there.
final class CellBus {
    weak var sessions: SessionManager?

    init(sessions: SessionManager) {
        self.sessions = sessions
    }

    /// Cap on how much of a cell's screen we return, so a long scrollback
    /// doesn't flood the calling agent's context. The tail is the recent part.
    private let readTailLimit = 6000

    func handle(verb: String, surfaceId: UUID, cell: Int?, text: String?) -> String {
        guard let sessions else { return "error: app not ready" }
        guard let workspace = sessions.workspace(containingSurfaceId: surfaceId) else {
            return "error: this terminal isn't a known workspace cell"
        }

        switch verb {
        case "cells":
            return listing(workspace, callerId: surfaceId)

        case "read":
            guard let target = nthCell(workspace, cell) else { return "error: no cell \(cell ?? 0)" }
            guard let view = target.terminal?.view else { return "error: cell \(cell ?? 0) is empty" }
            let screen = view.readScreenText() ?? ""
            return String(screen.suffix(readTailLimit))

        case "send":
            guard let target = nthCell(workspace, cell) else { return "error: no cell \(cell ?? 0)" }
            guard let view = target.terminal?.view else { return "error: cell \(cell ?? 0) is empty" }
            view.sendInput(text ?? "", submit: true)
            return "ok: sent to cell \(cell ?? 0)"

        case "status":
            guard let target = nthCell(workspace, cell) else { return "error: no cell \(cell ?? 0)" }
            guard let tab = target.terminal else { return "empty" }
            return statusWord(tab.status)

        default:
            return "error: unknown verb '\(verb)'"
        }
    }

    private func nthCell(_ workspace: Workspace, _ n: Int?) -> WorkspaceCell? {
        guard let n, n >= 1, n <= workspace.cells.count else { return nil }
        return workspace.cells[n - 1]
    }

    private func listing(_ workspace: Workspace, callerId: UUID) -> String {
        var lines: [String] = []
        for (i, cell) in workspace.cells.enumerated() {
            let n = i + 1
            let isSelf = cell.terminal?.id == callerId
            let what = cell.terminal?.title ?? "empty"
            let state = cell.terminal.map { statusWord($0.status) } ?? "-"
            lines.append("\(n): \(what) [\(state)]\(isSelf ? "  (you)" : "")")
        }
        return lines.isEmpty ? "(no cells)" : lines.joined(separator: "\n")
    }

    private func statusWord(_ status: TerminalTabStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .working: return "working"
        case .completed: return "completed"
        case .failed: return "failed"
        }
    }
}
