import Foundation
import Observation
import OSLog

/// Global, persisted list of `LaunchTool`s shown as cell launcher tiles. Backed
/// by `~/Library/Application Support/AgenticIDE/launch-tools.json`. The four
/// built-ins are always present (merged in on load); the user can toggle any of
/// them and add / edit / remove custom tools.
@Observable
final class LaunchToolStore {
    private(set) var tools: [LaunchTool]

    private let storeURL: URL
    private let log = Logger(subsystem: "com.fabio.AgenticIDE", category: "LaunchToolStore")

    /// Tools shown on the launcher tiles, in order.
    var enabledTools: [LaunchTool] { tools.filter(\.enabled) }

    init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil,
                                       create: true)) ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("AgenticIDE", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("launch-tools.json")

        if let data = try? Data(contentsOf: storeURL),
           let loaded = try? JSONDecoder().decode([LaunchTool].self, from: data) {
            self.tools = Self.mergingBuiltins(into: loaded)
        } else {
            self.tools = LaunchTool.defaults()
        }
    }

    // MARK: - Mutations

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let idx = tools.firstIndex(where: { $0.id == id }) else { return }
        tools[idx].enabled = enabled
        save()
    }

    @discardableResult
    func add(name: String, command: String, icon: String) -> LaunchTool {
        let tool = LaunchTool(name: name, command: command, icon: icon)
        tools.append(tool)
        save()
        return tool
    }

    func update(_ tool: LaunchTool) {
        guard let idx = tools.firstIndex(where: { $0.id == tool.id }) else { return }
        tools[idx] = tool
        save()
    }

    /// Removes a custom tool. Built-ins can't be removed (only toggled off).
    func remove(id: UUID) {
        tools.removeAll { $0.id == id && !$0.isBuiltin }
        save()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        tools.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    // MARK: - Persistence

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(tools)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            log.error("Failed to save launch-tools.json: \(error.localizedDescription)")
        }
    }

    /// Guarantees the four built-ins exist, preserving any loaded (toggled /
    /// edited) copy and appending any that a saved file predates.
    private static func mergingBuiltins(into loaded: [LaunchTool]) -> [LaunchTool] {
        var result = loaded
        for builtin in LaunchTool.defaults() where !result.contains(where: { $0.id == builtin.id }) {
            result.append(builtin)
        }
        return result
    }
}
