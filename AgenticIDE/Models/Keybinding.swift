import SwiftUI

/// A user-rebindable keyboard shortcut: a single key plus modifier flags.
/// Persisted, and converted to a SwiftUI `KeyboardShortcut` for the menus.
struct Keybinding: Codable, Hashable {
    /// Single character, lowercased (e.g. "b", ".").
    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    init(_ key: String, command: Bool = false, shift: Bool = false,
         option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    var modifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return m
    }

    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(key.first ?? " "), modifiers: modifiers)
    }

    /// Display string like "⌃⌘F" / "⌘⇧A", in the macOS modifier order.
    var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        switch key {
        case ".": s += "."
        case ",": s += ","
        case "/": s += "/"
        default: s += key.uppercased()
        }
        return s
    }

    /// Build from a captured key event. Requires at least Command or Control so
    /// it reads as a valid app/menu shortcut; returns nil otherwise.
    init?(event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers,
              let ch = chars.first, !ch.isWhitespace else { return nil }
        let flags = event.modifierFlags
        let cmd = flags.contains(.command)
        let ctrl = flags.contains(.control)
        guard cmd || ctrl else { return nil }
        self.init(String(ch).lowercased(),
                  command: cmd,
                  shift: flags.contains(.shift),
                  option: flags.contains(.option),
                  control: ctrl)
    }
}

/// Every rebindable command in the app, with its title + default shortcut.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case newProject
    case addProject
    case save
    case closeTab
    case speak
    case stopSpeak
    case ask
    case toggleExplorer
    case zoomCell
    case newWorkspace
    case toggleNotes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newProject:     return "New Project"
        case .addProject:     return "Add Existing Project"
        case .save:           return "Save"
        case .closeTab:       return "Close Editor Tab"
        case .speak:          return "Speak Selection"
        case .stopSpeak:      return "Stop Speaking"
        case .ask:            return "Ask"
        case .toggleExplorer: return "Toggle Explorer"
        case .zoomCell:       return "Zoom Cell"
        case .newWorkspace:   return "New Workspace"
        case .toggleNotes:    return "Toggle Notes"
        }
    }

    var defaultBinding: Keybinding {
        switch self {
        case .newProject:     return Keybinding("n", command: true)
        case .addProject:     return Keybinding("o", command: true, shift: true)
        case .save:           return Keybinding("s", command: true)
        case .closeTab:       return Keybinding("w", command: true, shift: true)
        case .speak:          return Keybinding("s", command: true, shift: true)
        case .stopSpeak:      return Keybinding(".", command: true, shift: true)
        case .ask:            return Keybinding("a", command: true, shift: true)
        case .toggleExplorer: return Keybinding("b", command: true, option: true)
        case .zoomCell:       return Keybinding("f", command: true, control: true)
        case .newWorkspace:   return Keybinding("t", command: true)
        case .toggleNotes:    return Keybinding("n", command: true, shift: true)
        }
    }
}
