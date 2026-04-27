import AppKit
import Foundation
import Observation

/// One tab in a project's tab bar. Owns the persistent NSView (and its
/// underlying ghostty surface) so the spawned process keeps running across
/// tab and project switches. Ephemeral — not persisted to disk.
@Observable
final class TerminalTab: Identifiable, Hashable {
    let id: UUID
    var title: String
    let command: String?
    let view: GhosttyTerminalView
    let createdAt: Date

    init(id: UUID = UUID(), title: String, config: SurfaceConfig) {
        self.id = id
        self.title = title
        self.command = config.command
        self.view = GhosttyTerminalView(config: config)
        self.createdAt = Date()
    }

    static func == (lhs: TerminalTab, rhs: TerminalTab) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
