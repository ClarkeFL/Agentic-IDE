import Foundation

/// A launcher tile available inside an empty workspace cell. The built-ins
/// (Server, Claude, Codex, Terminal) ship enabled and can be toggled or edited
/// but not deleted; the user can add custom CLI tools (name + command + icon)
/// in Settings → Launchers, and toggle which ones appear on the tiles.
struct LaunchTool: Identifiable, Codable, Hashable {
    /// How the tool spawns:
    /// - `.command` runs `command` via the login shell,
    /// - `.server` runs the project's per-project Run Server command (prompting
    ///   if it hasn't been set yet),
    /// - `.terminal` opens the default login shell.
    enum Role: String, Codable, Hashable { case command, server, terminal }

    var id: UUID
    var name: String
    var command: String
    var icon: String
    var enabled: Bool
    var role: Role
    var isBuiltin: Bool
    /// Flag this CLI uses to *append* to its system prompt, so the cell-bridge
    /// note is injected on launch (e.g. `--append-system-prompt`). nil = use the
    /// auto-detected default for the command's executable, if any. Empty string
    /// is treated the same as nil. Only used in multi-cell workspaces.
    var promptFlag: String?

    init(id: UUID = UUID(),
         name: String,
         command: String,
         icon: String,
         enabled: Bool = true,
         role: Role = .command,
         isBuiltin: Bool = false,
         promptFlag: String? = nil) {
        self.id = id
        self.name = name
        self.command = command
        self.icon = icon
        self.enabled = enabled
        self.role = role
        self.isBuiltin = isBuiltin
        self.promptFlag = promptFlag
    }

    /// Verified inline "append to system prompt" flags, keyed by the command's
    /// executable. These take a single quoted string argument and work while
    /// launching an interactive session. Other CLIs have no clean inline flag
    /// (they read AGENTS.md / a context file), so they stay manual unless the
    /// user sets `promptFlag` themselves.
    static func knownPromptFlag(forCommand command: String) -> String? {
        let exe = command.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init) ?? ""
        switch (exe as NSString).lastPathComponent {
        case "claude":            return "--append-system-prompt"
        case "qwen":              return "--append-system-prompt"
        case "cn", "continue":    return "--rule"
        default:                  return nil
        }
    }

    /// The flag actually used at launch: an explicit non-empty `promptFlag`
    /// wins, otherwise the auto-detected default for the executable.
    var effectivePromptFlag: String? {
        if let promptFlag, !promptFlag.isEmpty { return promptFlag }
        return Self.knownPromptFlag(forCommand: command)
    }

    /// Stable ids for the built-ins so their enabled/edited state survives a
    /// defaults merge and persists even before the first save.
    static let serverID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let claudeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let codexID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
    static let terminalID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!
    static let geminiID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A5")!
    static let kimiID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A7")!
    static let opencodeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A8")!

    static func defaults() -> [LaunchTool] {
        [
            // On by default.
            LaunchTool(id: serverID, name: "Server", command: "",
                       icon: "play.circle", role: .server, isBuiltin: true),
            LaunchTool(id: claudeID, name: "Claude", command: "claude",
                       icon: "brand:claude", role: .command, isBuiltin: true),
            // Codex is OpenAI's GPT-powered agent CLI (a.k.a. "GPT").
            LaunchTool(id: codexID, name: "Codex", command: "codex",
                       icon: "brand:codex", role: .command, isBuiltin: true),
            LaunchTool(id: terminalID, name: "Terminal", command: "",
                       icon: "terminal", role: .terminal, isBuiltin: true),
            // Extra agents ship OFF by default — toggle them on in
            // Settings → Launchers. Commands are editable if yours differ.
            LaunchTool(id: geminiID, name: "Gemini", command: "gemini",
                       icon: "sparkle", enabled: false, role: .command, isBuiltin: true),
            LaunchTool(id: kimiID, name: "Kimi", command: "kimi",
                       icon: "moon.stars", enabled: false, role: .command, isBuiltin: true),
            LaunchTool(id: opencodeID, name: "opencode", command: "opencode",
                       icon: "chevron.left.forwardslash.chevron.right",
                       enabled: false, role: .command, isBuiltin: true),
        ]
    }
}
