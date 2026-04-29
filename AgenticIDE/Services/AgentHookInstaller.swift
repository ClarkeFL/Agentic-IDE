import Foundation
import OSLog

/// Manages opt-in installation of agent lifecycle hooks for Claude Code and
/// OpenAI Codex. Each hook is a one-line shell snippet that writes a status
/// word ("working" / "completed") to the watcher's status directory, keyed
/// by `AGENTIDE_SURFACE_ID` (which `TerminalTab` injects into every PTY env).
///
/// The agent itself owns the JSON config files (`~/.claude/settings.json`,
/// `~/.codex/hooks.json`); we read, merge our entries in, and write back.
/// Existing user hooks are preserved verbatim — we only ever add or remove
/// entries marked with `agenticideMarker`.
enum AgentHookInstaller {
    private static let log = Logger(subsystem: "com.fabio.AgenticIDE",
                                    category: "AgentHookInstaller")

    /// Marker substring embedded in every shell command we write. The
    /// installer matches on this when uninstalling / upgrading so user-
    /// owned hooks in the same file are never touched.
    static let agenticideMarker = "# agenticide-hook"

    enum Agent: String, CaseIterable, Identifiable {
        case claude
        case codex

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "OpenAI Codex"
            }
        }

        /// Path to the agent's config file, expanded against $HOME at call
        /// time so a user with a custom $HOME (rare on macOS but possible
        /// inside sandboxed test runs) doesn't get the wrong location.
        var configPath: String {
            let home = NSHomeDirectory()
            switch self {
            case .claude: return "\(home)/.claude/settings.json"
            case .codex:  return "\(home)/.codex/hooks.json"
            }
        }

        /// Hook event names this agent fires for each lifecycle moment we
        /// care about. Both agents happen to use the same names; we keep
        /// them per-agent so future divergence (or extra agents) is easy.
        var workingEvent: String {
            switch self {
            case .claude: return "UserPromptSubmit"
            case .codex:  return "UserPromptSubmit"
            }
        }
        var completedEvent: String {
            switch self {
            case .claude: return "Stop"
            case .codex:  return "Stop"
            }
        }
    }

    enum InstallState {
        case installed
        case notInstalled
        /// Config file exists but couldn't be parsed — the user has hand-
        /// edited it into a state we can't safely merge into. Surface in
        /// the UI so they can fix or remove it.
        case configUnreadable
        /// Parent directory doesn't exist — the agent itself isn't
        /// installed yet, so we have nowhere to write hooks.
        case agentNotInstalled
    }

    // MARK: - Public API

    static func state(for agent: Agent) -> InstallState {
        let fm = FileManager.default
        let parent = (agent.configPath as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue else {
            return .agentNotInstalled
        }
        guard fm.fileExists(atPath: agent.configPath) else {
            return .notInstalled
        }
        guard let data = fm.contents(atPath: agent.configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .configUnreadable
        }
        guard let hooks = json["hooks"] as? [String: Any] else {
            return .notInstalled
        }
        let agentEvents = [agent.workingEvent, agent.completedEvent]
        for event in agentEvents {
            if hasAgenticideEntry(under: hooks[event]) { return .installed }
        }
        return .notInstalled
    }

    /// Idempotent install. Removes any prior agenticide entries first so the
    /// command body always reflects the current code (e.g. updated status-
    /// directory path), then appends fresh entries.
    static func install(_ agent: Agent) throws {
        try mutate(agent) { hooks in
            removeAgenticideEntries(from: &hooks)
            addAgenticideEntries(to: &hooks, agent: agent)
        }
    }

    static func uninstall(_ agent: Agent) throws {
        try mutate(agent) { hooks in
            removeAgenticideEntries(from: &hooks)
        }
    }

    // MARK: - Read / merge / write

    private static func mutate(_ agent: Agent,
                               _ body: (inout [String: Any]) -> Void) throws {
        let fm = FileManager.default
        let path = agent.configPath
        let parent = (path as NSString).deletingLastPathComponent

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(
                domain: "AgentHookInstaller",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                            "\(agent.displayName) is not installed (\(parent) does not exist)."]
            )
        }

        var root: [String: Any] = [:]
        if fm.fileExists(atPath: path), let data = fm.contents(atPath: path) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(
                    domain: "AgentHookInstaller",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                                "\(path) exists but is not valid JSON. Remove or repair it before installing hooks."]
                )
            }
            root = parsed
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        body(&hooks)
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }

        let data = try JSONSerialization.data(withJSONObject: root,
                                               options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        log.info("Wrote \(path, privacy: .public)")
    }

    /// Removes only `agenticide-hook`-marked entries. Other groups / commands
    /// in the same event are preserved untouched, including ones the user
    /// authored manually.
    private static func removeAgenticideEntries(from hooks: inout [String: Any]) {
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var rewritten: [[String: Any]] = []
            for var group in groups {
                guard var inner = group["hooks"] as? [[String: Any]] else {
                    rewritten.append(group)
                    continue
                }
                inner.removeAll { entry in
                    let cmd = entry["command"] as? String ?? ""
                    return cmd.contains(agenticideMarker)
                }
                if inner.isEmpty { continue }
                group["hooks"] = inner
                rewritten.append(group)
            }
            if rewritten.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = rewritten
            }
        }
    }

    private static func addAgenticideEntries(to hooks: inout [String: Any], agent: Agent) {
        let working = command(forStatus: "working")
        let completed = command(forStatus: "completed")

        appendNestedHook(into: &hooks, event: agent.workingEvent, command: working)
        appendNestedHook(into: &hooks, event: agent.completedEvent, command: completed)
    }

    private static func appendNestedHook(into hooks: inout [String: Any],
                                         event: String,
                                         command: String) {
        var groups = hooks[event] as? [[String: Any]] ?? []
        groups.append([
            "hooks": [[
                "type": "command",
                "command": command,
                "timeout": 5
            ] as [String: Any]]
        ] as [String: Any])
        hooks[event] = groups
    }

    /// Builds the shell snippet the agent will run. Guards on
    /// `AGENTIDE_SURFACE_ID` so an agent invoked outside an Agentic IDE
    /// terminal silently no-ops (e.g. the user runs claude in a regular
    /// Terminal.app — we don't want to write status files for surfaces
    /// nobody's watching).
    private static func command(forStatus status: String) -> String {
        let dir = AgentStatusWatcher.statusDirectoryURL.path
        // Escape the directory path for inclusion inside double quotes —
        // realistic paths under ~/Library/Application Support/AgenticIDE
        // don't contain `"` or `\` but be defensive.
        let escapedDir = dir
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "[ -n \"$AGENTIDE_SURFACE_ID\" ] && mkdir -p \"\(escapedDir)\" && printf '%s' \(status) > \"\(escapedDir)/$AGENTIDE_SURFACE_ID\" \(agenticideMarker)"
    }

    private static func hasAgenticideEntry(under value: Any?) -> Bool {
        guard let groups = value as? [[String: Any]] else { return false }
        for group in groups {
            guard let inner = group["hooks"] as? [[String: Any]] else { continue }
            for entry in inner {
                if let cmd = entry["command"] as? String, cmd.contains(agenticideMarker) {
                    return true
                }
            }
        }
        return false
    }
}
