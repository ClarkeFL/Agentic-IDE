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

    init(id: UUID = UUID(), icon: String? = nil, terminal: TerminalTab? = nil) {
        self.id = id
        self.icon = icon
        self.terminal = terminal
    }

    var isEmpty: Bool { terminal == nil }
}
