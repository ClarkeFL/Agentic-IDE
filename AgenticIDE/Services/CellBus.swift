import Foundation

/// Resolves agent-bridge requests against the live workspace grid. A caller can
/// list / read / drive its sibling cells, and also reshape its own workspace:
/// resize the grid, launch a tool into a cell, or close one. Everything is
/// scoped to the caller's own workspace (resolved from its surface id), so an
/// orchestrator agent can't reach across projects. All methods touch Ghostty
/// surfaces + Observable model state, so they run on the main thread
/// (`AgentBridge` dispatches them there).
final class CellBus {
    weak var sessions: SessionManager?
    weak var store: ProjectStore?
    weak var launchTools: LaunchToolStore?

    init(sessions: SessionManager, store: ProjectStore, launchTools: LaunchToolStore) {
        self.sessions = sessions
        self.store = store
        self.launchTools = launchTools
    }

    /// Cap on how much of a cell's screen we return so a long scrollback doesn't
    /// flood the calling agent's context. The tail is the recent part.
    private let readTailLimit = 6000

    func handle(verb: String, surfaceId: UUID, args: [String], body: String?) -> String {
        guard let sessions, let located = sessions.locate(surfaceId: surfaceId) else {
            return "error: this terminal isn't a known workspace cell"
        }
        let session = located.session
        let workspace = located.workspace

        switch verb {
        case "cells":
            return listing(workspace, callerId: surfaceId)

        case "tools":
            return toolListing()

        case "read":
            guard let cell = nthCell(workspace, intArg(args, 0)) else { return noCell(args, 0) }
            guard let view = cell.terminal?.view else { return "error: cell \(args.first ?? "?") is empty" }
            return String((view.readScreenText() ?? "").suffix(readTailLimit))

        case "status":
            guard let cell = nthCell(workspace, intArg(args, 0)) else { return noCell(args, 0) }
            return cell.terminal.map { statusWord($0.status) } ?? "empty"

        case "send":
            guard let cell = nthCell(workspace, intArg(args, 0)) else { return noCell(args, 0) }
            guard let view = cell.terminal?.view else { return "error: cell \(args.first ?? "?") is empty" }
            view.sendInput(body ?? "", submit: true)
            return "ok: sent to cell \(args.first ?? "?")"

        case "close":
            guard let cell = nthCell(workspace, intArg(args, 0)) else { return noCell(args, 0) }
            session.closeCell(cell)
            return "ok: closed cell \(args.first ?? "?")"

        case "grid":
            guard let layout = parseLayout(args) else {
                return "error: usage: grid <rows> <cols>  OR  grid rows|cols <n> <n>...  (max 8 cells)"
            }
            session.resizeWorkspace(workspace, layout: layout)
            return "ok: grid is now \(workspace.layoutDescription) (\(workspace.cellCount) cells)"

        case "launch":
            guard let cell = nthCell(workspace, intArg(args, 0)) else { return noCell(args, 0) }
            return launch(toolName: body ?? "", into: cell, session: session, workspace: workspace)

        default:
            return "error: unknown verb '\(verb)'"
        }
    }

    /// `browser` verbs act on the CALLER's own browser pane (keyed by its
    /// surface id), unlike the cell-number verbs above. Async because
    /// WKWebView's DOM access is — `AgentBridge` parks the socket thread on a
    /// semaphore until `completion` fires.
    func handleBrowser(surfaceId: UUID, args: [String], body: String?,
                       completion: @escaping (String) -> Void) {
        guard let sessions, let located = sessions.locate(surfaceId: surfaceId),
              let ownerCell = located.workspace.cells
                  .first(where: { $0.terminal?.id == surfaceId }) else {
            completion("error: this terminal isn't a known workspace cell")
            return
        }
        let manager = BrowserManager.shared
        let usage = "error: usage: browser open [url] | browser read | browser eval <js> | "
            + "browser html [selector] | browser wait <js-expr> | "
            + "browser reload | browser back | browser forward | "
            + "browser errors | browser logs | browser screenshot [selector] | "
            + "browser viewport <fit|desktop|laptop|tablet|mobile> | browser close"

        switch args.first ?? "" {
        case "open":
            let raw = args.dropFirst().first ?? body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if raw.isEmpty || raw == "about:blank" {
                manager.open(nil, cell: ownerCell)
                completion("ok: opened blank start page — navigate with `agentide browser open <url>`")
                return
            }
            guard let url = BrowserManager.normalizeURL(raw) else {
                completion("error: '\(raw)' is not a valid URL — usage: browser open <url>")
                return
            }
            let session = manager.open(url, cell: ownerCell)
            session.whenLoaded { loaded in
                completion("ok: opened \(url.absoluteString)"
                           + (loaded ? "" : " (page still loading after 10s)")
                           + " — the user can see this browser; "
                           + "use `agentide browser read` / `agentide browser eval` to drive it")
            }

        case "read":
            guard let session = manager.session(for: ownerCell) else {
                completion("error: no browser open — use `agentide browser open <url>` first")
                return
            }
            session.whenLoaded { _ in
                session.snapshot { completion(String($0.prefix(8000))) }
            }

        case "reload":
            guard let session = manager.session(for: ownerCell) else {
                completion("error: no browser open — use `agentide browser open <url>` first")
                return
            }
            guard !session.urlString.isEmpty else {
                completion("error: nothing loaded — use `agentide browser open <url>` first")
                return
            }
            session.webView.reloadFromOrigin()
            session.whenLoaded { loaded in
                completion(loaded ? "ok: reloaded \(session.urlString)"
                                  : "ok: reload issued — page still loading after 10s")
            }

        case "back":
            guard let session = manager.session(for: ownerCell) else {
                completion("error: no browser open — use `agentide browser open <url>` first")
                return
            }
            guard session.webView.canGoBack else {
                completion("error: no page to go back to")
                return
            }
            session.webView.goBack()
            session.whenLoaded { _ in
                completion("ok: went back to \(session.webView.url?.absoluteString ?? "previous page")")
            }

        case "forward":
            guard let session = manager.session(for: ownerCell) else {
                completion("error: no browser open — use `agentide browser open <url>` first")
                return
            }
            guard session.webView.canGoForward else {
                completion("error: no page to go forward to")
                return
            }
            session.webView.goForward()
            session.whenLoaded { _ in
                completion("ok: went forward to \(session.webView.url?.absoluteString ?? "next page")")
            }

        case "wait":
            guard let session = manager.session(for: ownerCell) else {
                completion("error: no browser open — use `agentide browser open <url>` first")
                return
            }
            let expr = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !expr.isEmpty else {
                completion("error: usage: browser wait <js-expression>")
                return
            }
            session.waitFor(expr, completion: completion)

        case "html":
            guard let session = manager.session(for: ownerCell) else {
                completion("error: no browser open — use `agentide browser open <url>` first")
                return
            }
            let selector = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            session.html(selector: selector) { completion(String($0.prefix(8000))) }

        case "eval":
            guard let session = manager.session(for: ownerCell) else {
                completion("error: no browser open — use `agentide browser open <url>` first")
                return
            }
            let js = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !js.isEmpty else {
                completion("error: usage: browser eval <javascript>")
                return
            }
            session.eval(js) { completion(String($0.prefix(8000))) }

        case "errors":
            guard let session = manager.session(for: ownerCell) else {
                completion("error: no browser open — use `agentide browser open <url>` first")
                return
            }
            session.consoleErrors { completion(String($0.prefix(8000))) }

        case "logs":
            guard let session = manager.session(for: ownerCell) else {
                completion("error: no browser open — use `agentide browser open <url>` first")
                return
            }
            session.consoleLogs { completion(String($0.prefix(8000))) }

        case "screenshot":
            guard let session = manager.session(for: ownerCell) else {
                completion("error: no browser open — use `agentide browser open <url>` first")
                return
            }
            let target = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            session.screenshot(selector: target, completion: completion)

        case "viewport":
            guard let session = manager.session(for: ownerCell) else {
                completion("error: no browser open — use `agentide browser open <url>` first")
                return
            }
            let name = args.dropFirst().first ?? ""
            guard let viewport = BrowserViewport(rawValue: name) else {
                completion("error: usage: browser viewport <fit|desktop|laptop|tablet|mobile>")
                return
            }
            session.viewport = viewport
            if let size = viewport.size {
                completion("ok: viewport \(name) — page now lays out at \(Int(size.width))×\(Int(size.height))")
            } else {
                completion("ok: viewport fit — page fills the pane")
            }

        case "close":
            guard let session = manager.session(for: ownerCell) else {
                completion("error: no browser open")
                return
            }
            manager.close(session)
            completion("ok: browser closed")

        default:
            completion(usage)
        }
    }

    // MARK: - launch

    private func launch(toolName: String, into cell: WorkspaceCell,
                        session: ProjectSession, workspace: Workspace) -> String {
        guard let store, let launchTools else { return "error: app not ready" }
        let name = toolName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "error: usage: launch <n> <tool>" }
        guard let tool = launchTools.tools.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            let available = launchTools.tools.map(\.name).joined(separator: ", ")
            return "error: no tool named '\(name)'. Available: \(available)"
        }
        guard let project = store.projects.first(where: { $0.id == session.projectId }) else {
            return "error: project not found"
        }
        let launcher = CellLauncher(project: project, session: session, workspace: workspace, store: store)
        if let err = launcher.launch(tool, into: cell) { return "error: \(err)" }
        let n = (workspace.cells.firstIndex(where: { $0.id == cell.id }) ?? 0) + 1
        return "ok: launched \(tool.name) in cell \(n)"
    }

    // MARK: - Listings

    private func listing(_ workspace: Workspace, callerId: UUID) -> String {
        var lines: [String] = ["grid: \(workspace.layoutDescription)"]
        for (i, cell) in workspace.cells.enumerated() {
            let n = i + 1
            let isSelf = cell.terminal?.id == callerId
            let what = cell.terminal?.title ?? "empty"
            let state = cell.terminal.map { statusWord($0.status) } ?? "-"
            lines.append("\(n): \(what) [\(state)]\(isSelf ? "  (you)" : "")")
        }
        return lines.joined(separator: "\n")
    }

    private func toolListing() -> String {
        guard let launchTools else { return "error: app not ready" }
        let lines = launchTools.tools.map { tool -> String in
            let detail: String
            switch tool.role {
            case .server:   detail = "per-project Run Server command"
            case .terminal: detail = "login shell"
            case .command:  detail = tool.command
            }
            return "\(tool.name) — \(detail)\(tool.enabled ? "" : " (disabled)")"
        }
        return lines.isEmpty ? "(no tools)" : lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func nthCell(_ workspace: Workspace, _ n: Int?) -> WorkspaceCell? {
        guard let n, n >= 1, n <= workspace.cells.count else { return nil }
        return workspace.cells[n - 1]
    }

    private func intArg(_ args: [String], _ i: Int) -> Int? {
        i < args.count ? Int(args[i]) : nil
    }

    /// Accepts either the legacy `grid <rows> <cols>` (a uniform rectangle) or
    /// the new `grid rows|cols <n> <n>...` (uneven groups). Returns nil on
    /// unparseable input; `apply` clamps anything out of range.
    private func parseLayout(_ args: [String]) -> GridLayout? {
        if let axis = args.first.flatMap({ LayoutAxis(rawValue: $0.lowercased()) }) {
            let counts = args.dropFirst().compactMap { Int($0) }.filter { $0 > 0 }
            return counts.isEmpty ? nil : GridLayout(axis: axis, counts: counts)
        }
        if let rows = intArg(args, 0), let cols = intArg(args, 1), rows > 0, cols > 0 {
            return GridLayout(axis: .rows, counts: Array(repeating: cols, count: rows))
        }
        return nil
    }

    private func noCell(_ args: [String], _ i: Int) -> String {
        "error: no cell \(i < args.count ? args[i] : "?")"
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
