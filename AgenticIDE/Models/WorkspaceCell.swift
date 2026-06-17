import Foundation
import Observation

/// One cell in a workspace grid. Holds at most one live terminal (one program
/// per cell). `terminal == nil` means the cell is empty and shows the launcher.
@Observable
final class WorkspaceCell: Identifiable {
    let id: UUID
    /// Icon of the launcher that started this cell, denormalised so the header
    /// shows the right glyph and it survives the originating `LaunchTool` being
    /// edited or removed. nil when the cell is empty.
    var icon: String?
    var terminal: TerminalTab?
    /// When true, this cell's agent is briefed as the workspace ORCHESTRATOR:
    /// it gets the orchestration system prompt on launch and a runtime briefing
    /// when promoted live. Drives heavy, proactive use of the cell grid.
    /// Runtime-only (not persisted) — resets to false on app restart.
    var isOrchestrator: Bool

    init(id: UUID = UUID(), icon: String? = nil, terminal: TerminalTab? = nil,
         isOrchestrator: Bool = false) {
        self.id = id
        self.icon = icon
        self.terminal = terminal
        self.isOrchestrator = isOrchestrator
    }

    var isEmpty: Bool { terminal == nil }
}
