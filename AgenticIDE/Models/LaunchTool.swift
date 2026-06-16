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

    init(id: UUID = UUID(),
         name: String,
         command: String,
         icon: String,
         enabled: Bool = true,
         role: Role = .command,
         isBuiltin: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.icon = icon
        self.enabled = enabled
        self.role = role
        self.isBuiltin = isBuiltin
    }

    /// Stable ids for the built-ins so their enabled/edited state survives a
    /// defaults merge and persists even before the first save.
    static let serverID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let claudeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let codexID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
    static let terminalID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!

    static func defaults() -> [LaunchTool] {
        [
            LaunchTool(id: serverID, name: "Server", command: "",
                       icon: "play.circle", role: .server, isBuiltin: true),
            LaunchTool(id: claudeID, name: "Claude", command: "claude",
                       icon: "brand:claude", role: .command, isBuiltin: true),
            LaunchTool(id: codexID, name: "Codex", command: "codex",
                       icon: "brand:codex", role: .command, isBuiltin: true),
            LaunchTool(id: terminalID, name: "Terminal", command: "",
                       icon: "terminal", role: .terminal, isBuiltin: true),
        ]
    }
}
