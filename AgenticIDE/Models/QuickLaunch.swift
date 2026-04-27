import Foundation

/// A launch button that appears in a project's tab bar.
struct QuickLaunch: Identifiable, Codable, Hashable {
    var id: UUID
    var label: String
    /// Shell command to run. Empty string means "prompt the user on first click".
    var command: String
    var icon: String?
    /// Built-ins (Run Server / Claude / Codex) cannot be deleted, only edited.
    var isBuiltin: Bool

    init(id: UUID = UUID(), label: String, command: String, icon: String? = nil, isBuiltin: Bool = false) {
        self.id = id
        self.label = label
        self.command = command
        self.icon = icon
        self.isBuiltin = isBuiltin
    }

    static func defaults() -> [QuickLaunch] {
        [
            QuickLaunch(label: "Run Server", command: "", icon: "play.circle", isBuiltin: true),
            QuickLaunch(label: "Claude",     command: "claude", icon: "sparkles", isBuiltin: true),
            QuickLaunch(label: "Codex",      command: "codex",  icon: "wand.and.stars", isBuiltin: true),
        ]
    }
}
