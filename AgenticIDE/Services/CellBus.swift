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

        case "servers":
            return serverListing(session: session)

        case "server":
            return handleServer(args: args, body: body, session: session)

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

        let projectSession = located.session
        let workspace = located.workspace

        switch args.first ?? "" {
        case "open":
            let raw = args.dropFirst().first ?? body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if raw.isEmpty || raw == "about:blank" {
                manager.open(nil, cell: ownerCell,
                             workspace: workspace, projectSession: projectSession)
                completion("ok: opened blank start page — navigate with `agentide browser open <url>`")
                return
            }
            guard let url = BrowserManager.normalizeURL(raw) else {
                completion("error: '\(raw)' is not a valid URL — usage: browser open <url>")
                return
            }
            let session = manager.open(url, cell: ownerCell,
                                       workspace: workspace, projectSession: projectSession)
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
        // Dev servers belong in the dedicated Servers workspace, not a grid cell.
        if name.caseInsensitiveCompare("server") == .orderedSame {
            return "error: do not launch servers into grid cells — use "
                + "`agentide servers` to list, `agentide server run [name|all]`, "
                + "or `agentide server run <name> <command>` for an ad-hoc server. "
                + "They run in the dedicated Servers workspace."
        }
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

    // MARK: - Servers workspace

    private func runner(for session: ProjectSession) -> ServerRunner? {
        guard let store,
              let project = store.projects.first(where: { $0.id == session.projectId }) else {
            return nil
        }
        return ServerRunner(project: project, session: session, store: store)
    }

    private func serverListing(session: ProjectSession) -> String {
        guard let store,
              let project = store.projects.first(where: { $0.id == session.projectId }),
              let runner = runner(for: session) else {
            return "error: app not ready"
        }
        let live = runner.runningLabels()
        var lines: [String] = [
            "Servers workspace: dedicated place for long-running dev servers "
                + "(not grid cells). Use `agentide server run [name|all]` / "
                + "`agentide server stop [name|all]` / `agentide server read <name>`.",
        ]
        if project.servers.isEmpty && live.isEmpty {
            lines.append("(no servers configured — run ad-hoc with "
                + "`agentide server run <name> <command>`, e.g. "
                + "`agentide server run web npm run dev`)")
            return lines.joined(separator: "\n")
        }
        for s in project.servers {
            let state = live.contains(s.label) ? "running" : "stopped"
            lines.append("\(s.label): [\(state)]  \(s.command)")
        }
        // Ad-hoc / leftover cells not in the configured list.
        for label in live.sorted() where !project.servers.contains(where: { $0.label == label }) {
            lines.append("\(label): [running]  (ad-hoc)")
        }
        return lines.joined(separator: "\n")
    }

    private func handleServer(args: [String], body: String?,
                              session: ProjectSession) -> String {
        guard let store,
              let project = store.projects.first(where: { $0.id == session.projectId }),
              let runner = runner(for: session) else {
            return "error: app not ready"
        }
        let usage = "error: usage: server run [name|all] | server run <name> <command> | "
            + "server stop [name|all] | server read <name>"
        guard let sub = args.first?.lowercased() else { return usage }
        let rest = Array(args.dropFirst())
        let name = rest.first ?? ""
        let cmdFromArgs = rest.dropFirst().joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let cmdFromBody = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let command = !cmdFromBody.isEmpty ? cmdFromBody : cmdFromArgs

        switch sub {
        case "run":
            return serverRun(name: name, command: command, project: project, runner: runner)
        case "stop":
            return serverStop(name: name, runner: runner)
        case "read":
            return serverRead(name: name, runner: runner)
        default:
            return usage
        }
    }

    private func serverRun(name: String, command: String,
                           project: Project, runner: ServerRunner) -> String {
        let live = runner.runningLabels()
        // No name / "all" → run every configured server.
        if name.isEmpty || name.caseInsensitiveCompare("all") == .orderedSame {
            guard !project.servers.isEmpty else {
                return "error: no servers configured for this project — "
                    + "use `agentide server run <name> <command>` for an ad-hoc server "
                    + "(e.g. `agentide server run web npm run dev`), or set servers up in the bar"
            }
            let already = project.servers.filter { live.contains($0.label) }.map(\.label)
            runner.run(project.servers, activate: false)
            let started = project.servers.map(\.label).filter { !already.contains($0) }
            if started.isEmpty {
                return "ok: all configured servers already running (\(already.joined(separator: ", ")))"
            }
            let note = already.isEmpty ? "" : "; already running: \(already.joined(separator: ", "))"
            return "ok: started \(started.joined(separator: ", ")) in Servers workspace\(note)"
        }

        // Named configured server (optional command override ignored if empty).
        if let configured = project.servers.first(where: {
            $0.label.caseInsensitiveCompare(name) == .orderedSame
        }) {
            if live.contains(configured.label) {
                return "ok: \(configured.label) already running in Servers workspace"
            }
            let ql = command.isEmpty
                ? configured
                : QuickLaunch(id: configured.id, label: configured.label, command: command)
            runner.run([ql], activate: false)
            return "ok: started \(configured.label) in Servers workspace"
        }

        // Ad-hoc: name + command → one-shot into Servers workspace.
        if !command.isEmpty {
            if live.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                return "ok: \(name) already running in Servers workspace"
            }
            let ql = QuickLaunch(label: name, command: command, icon: "play.circle")
            runner.run([ql], activate: false)
            return "ok: started ad-hoc server '\(name)' in Servers workspace (\(command))"
        }

        let available = project.servers.map(\.label)
        let hint = available.isEmpty
            ? "no configured servers — pass a command: `agentide server run \(name) <command>`"
            : "unknown server '\(name)'. Configured: \(available.joined(separator: ", ")). "
                + "Or run ad-hoc: `agentide server run \(name) <command>`"
        return "error: \(hint)"
    }

    private func serverStop(name: String, runner: ServerRunner) -> String {
        let live = runner.runningLabels()
        if name.isEmpty || name.caseInsensitiveCompare("all") == .orderedSame {
            guard !live.isEmpty else { return "ok: no servers running" }
            runner.stopAll()
            return "ok: stopped all servers (\(live.sorted().joined(separator: ", ")))"
        }
        guard let match = live.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            let hint = live.isEmpty
                ? "none running"
                : "running: \(live.sorted().joined(separator: ", "))"
            return "error: '\(name)' is not running (\(hint))"
        }
        runner.stop(match)
        return "ok: stopped \(match)"
    }

    private func serverRead(name: String, runner: ServerRunner) -> String {
        guard !name.isEmpty else {
            return "error: usage: server read <name>"
        }
        guard let cell = runner.cell(named: name)
                ?? runner.runningLabels()
                    .first(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
                    .flatMap({ runner.cell(named: $0) }) else {
            let live = runner.runningLabels()
            let hint = live.isEmpty
                ? "none running"
                : "running: \(live.sorted().joined(separator: ", "))"
            return "error: no running server named '\(name)' (\(hint))"
        }
        guard let view = cell.terminal?.view else {
            return "error: server '\(name)' has no terminal"
        }
        return String((view.readScreenText() ?? "").suffix(readTailLimit))
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
            case .server:   detail = "UI only — agents must use `agentide server run` (Servers workspace)"
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
