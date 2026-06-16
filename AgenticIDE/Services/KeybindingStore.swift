import Foundation
import Observation
import OSLog
import SwiftUI

/// Persisted keyboard-shortcut overrides. The menus read every shortcut through
/// `shortcut(for:)`, so rebinding here updates them. Backed by
/// `~/Library/Application Support/AgenticIDE/keybindings.json`.
@Observable
final class KeybindingStore {
    /// Overrides keyed by action. Actions without an override use the default.
    private(set) var overrides: [ShortcutAction: Keybinding] = [:]

    private let storeURL: URL
    private let log = Logger(subsystem: "com.fabio.AgenticIDE", category: "KeybindingStore")

    init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("AgenticIDE", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("keybindings.json")

        if let data = try? Data(contentsOf: storeURL),
           let raw = try? JSONDecoder().decode([String: Keybinding].self, from: data) {
            for (key, binding) in raw {
                if let action = ShortcutAction(rawValue: key) { overrides[action] = binding }
            }
        }
    }

    /// The effective binding for an action (override or default).
    func binding(for action: ShortcutAction) -> Keybinding {
        overrides[action] ?? action.defaultBinding
    }

    func shortcut(for action: ShortcutAction) -> KeyboardShortcut {
        binding(for: action).keyboardShortcut
    }

    func isOverridden(_ action: ShortcutAction) -> Bool {
        overrides[action] != nil
    }

    /// True when another action already uses this exact combo.
    func conflict(for action: ShortcutAction, binding: Keybinding) -> ShortcutAction? {
        ShortcutAction.allCases.first { other in
            other != action && self.binding(for: other) == binding
        }
    }

    func set(_ binding: Keybinding, for action: ShortcutAction) {
        if binding == action.defaultBinding {
            overrides.removeValue(forKey: action)
        } else {
            overrides[action] = binding
        }
        save()
    }

    func reset(_ action: ShortcutAction) {
        overrides.removeValue(forKey: action)
        save()
    }

    func resetAll() {
        overrides.removeAll()
        save()
    }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(raw).write(to: storeURL, options: [.atomic])
        } catch {
            log.error("Failed to save keybindings.json: \(error.localizedDescription)")
        }
    }
}
