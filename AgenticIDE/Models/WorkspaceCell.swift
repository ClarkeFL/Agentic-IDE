import Foundation
import Observation

/// What a workspace cell is running. Drives the launcher buttons, the cell's
/// icon, and persistence (so a re-spawned cell shows the right glyph before its
/// process has printed anything). `terminal` on the cell is the source of truth
/// for the live process; `kind` is the lightweight label that survives a quit.
enum WorkspaceCellKind: String, Codable, CaseIterable, Hashable {
    case server
    case claude
    case codex
    case terminal

    var label: String {
        switch self {
        case .server:   return "Server"
        case .claude:   return "Claude"
        case .codex:    return "Codex"
        case .terminal: return "Terminal"
        }
    }

    /// Icon string understood by `quickLaunchIcon(name:)` — `brand:` prefixes
    /// render the custom logos, everything else is an SF Symbol.
    var icon: String {
        switch self {
        case .server:   return "play.circle"
        case .claude:   return "brand:claude"
        case .codex:    return "brand:codex"
        case .terminal: return "terminal"
        }
    }

    /// Label of the project `QuickLaunch` this kind pulls its command from, or
    /// nil for `.terminal` (which uses the default login shell). Lets a cell
    /// reuse the project's saved Server/Claude/Codex command (incl. any edits).
    var quickLaunchLabel: String? {
        switch self {
        case .server:   return "Run Server"
        case .claude:   return "Claude"
        case .codex:    return "Codex"
        case .terminal: return nil
        }
    }
}

/// One cell in a workspace grid. Holds at most one live terminal (one program
/// per cell). `terminal == nil` means the cell is empty and shows the launcher.
@Observable
final class WorkspaceCell: Identifiable {
    let id: UUID
    var kind: WorkspaceCellKind?
    var terminal: TerminalTab?

    init(id: UUID = UUID(), kind: WorkspaceCellKind? = nil, terminal: TerminalTab? = nil) {
        self.id = id
        self.kind = kind
        self.terminal = terminal
    }

    var isEmpty: Bool { terminal == nil }
}
