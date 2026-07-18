import Foundation

/// A launch button that appears in a project's tab bar, or a named dev server
/// row (`Project.servers`). Servers may carry an optional preferred TCP port.
struct QuickLaunch: Identifiable, Codable, Hashable {
    var id: UUID
    var label: String
    /// Shell command to run. Empty string means "prompt the user on first click".
    var command: String
    var icon: String?
    /// Built-ins (Run Server / Claude / Codex) cannot be deleted, only edited.
    var isBuiltin: Bool
    /// Preferred listen port for project servers (nil = not tracked). Injected
    /// as `PORT` / `AGENTIDE_PORT` when the server is started.
    var port: Int?

    init(id: UUID = UUID(), label: String, command: String, icon: String? = nil,
         isBuiltin: Bool = false, port: Int? = nil) {
        self.id = id
        self.label = label
        self.command = command
        self.icon = icon
        self.isBuiltin = isBuiltin
        self.port = port
    }

    enum CodingKeys: String, CodingKey {
        case id, label, command, icon, isBuiltin, port
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        command = try c.decode(String.self, forKey: .command)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        isBuiltin = try c.decodeIfPresent(Bool.self, forKey: .isBuiltin) ?? false
        port = try c.decodeIfPresent(Int.self, forKey: .port)
    }

    static func defaults() -> [QuickLaunch] {
        [
            QuickLaunch(label: "Run Server", command: "", icon: "play.circle", isBuiltin: true),
            QuickLaunch(label: "Claude",     command: "claude", icon: "sparkles", isBuiltin: true),
            QuickLaunch(label: "Codex",      command: "codex",  icon: "wand.and.stars", isBuiltin: true),
        ]
    }
}
