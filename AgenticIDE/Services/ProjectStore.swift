import AppKit
import Foundation
import Observation
import OSLog

/// Loads and saves the user's projects and groups list. Backed by a single
/// JSON file at `~/Library/Application Support/AgenticIDE/projects.json`.
/// Atomic writes. Reads tolerate the legacy `[Project]` format from v1.
@Observable
final class ProjectStore {
    private let log = Logger(subsystem: "com.fabio.AgenticIDE", category: "ProjectStore")

    private(set) var projects: [Project] = []
    private(set) var groups: [ProjectGroup] = []

    private let storeURL: URL
    /// Serial queue used to encode + atomic-write the JSON off the main
    /// thread. Mutations on main schedule a save here with a small debounce
    /// so a burst of changes (drag-reorder, smart-rename, etc.) collapses
    /// into a single fsync.
    private let saveQueue = DispatchQueue(label: "com.fabio.AgenticIDE.ProjectStore.save",
                                          qos: .utility)
    @ObservationIgnored
    private var pendingSave: DispatchWorkItem?
    /// Debounce window between mutation and the actual write. Long enough to
    /// coalesce realistic bursts; short enough that a crash within the window
    /// only loses the most recent change.
    private let saveDebounce: DispatchTimeInterval = .milliseconds(120)
    @ObservationIgnored
    private var terminationObserver: NSObjectProtocol?

    init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil,
                                       create: true)) ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("AgenticIDE", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("projects.json")
        load()
        // Flush any pending debounced write on app quit so changes inside the
        // 120 ms window aren't lost.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushSync()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: - Project mutations

    func add(_ project: Project) {
        projects.append(project)
        save()
    }

    func add(folder url: URL) -> Project {
        let p = Project(name: url.lastPathComponent, path: url)
        add(p)
        return p
    }

    func remove(id: UUID) {
        projects.removeAll { $0.id == id }
        save()
    }

    func setArchived(id: UUID, archived: Bool) {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[idx].archived = archived
        save()
    }

    func update(_ project: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx] = project
        save()
    }

    /// Replaces a single QuickLaunch on a project (matched by ql.id) and persists.
    func updateQuickLaunch(projectId: UUID, _ ql: QuickLaunch) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        guard let qIdx = projects[pIdx].quickLaunches.firstIndex(where: { $0.id == ql.id }) else { return }
        projects[pIdx].quickLaunches[qIdx] = ql
        save()
    }

    func recordActivity(projectId: UUID, command: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].lastActivityAt = Date()
        projects[idx].lastActivityCommand = command
        save()
    }

    func setProjectGroup(projectId: UUID, groupId: UUID?) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].groupId = groupId
        save()
    }

    // MARK: - Group mutations

    @discardableResult
    func addGroup(name: String) -> ProjectGroup {
        let nextOrder = (groups.map { $0.sortOrder }.max() ?? -1) + 1
        let g = ProjectGroup(name: name, sortOrder: nextOrder)
        groups.append(g)
        save()
        return g
    }

    func renameGroup(id: UUID, to name: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].name = name
        save()
    }

    /// Deletes a group; any projects that belonged to it become Ungrouped.
    func removeGroup(id: UUID) {
        groups.removeAll { $0.id == id }
        for i in projects.indices where projects[i].groupId == id {
            projects[i].groupId = nil
        }
        save()
    }

    var sortedGroups: [ProjectGroup] {
        groups.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Move a group so it sits immediately before `targetId`. If `targetId`
    /// is nil the group goes to the end of the list. Indexes are renumbered
    /// densely so future inserts stay predictable.
    func reorderGroup(id: UUID, before targetId: UUID?) {
        guard id != targetId else { return }
        var ordered = sortedGroups
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return }
        let moving = ordered.remove(at: from)
        if let targetId, let to = ordered.firstIndex(where: { $0.id == targetId }) {
            ordered.insert(moving, at: to)
        } else {
            ordered.append(moving)
        }
        for (i, g) in ordered.enumerated() {
            if let idx = groups.firstIndex(where: { $0.id == g.id }) {
                groups[idx].sortOrder = i
            }
        }
        save()
    }

    // MARK: - Persistence

    /// On-disk envelope. Older files were just `[Project]` — `load()` falls
    /// back to that shape.
    private struct StoreFile: Codable {
        var version: Int
        var projects: [Project]
        var groups: [ProjectGroup]
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let file = try? decoder.decode(StoreFile.self, from: data) {
                projects = file.projects
                groups = file.groups
            } else {
                // Legacy v1: bare [Project] array, no groups.
                projects = try decoder.decode([Project].self, from: data)
                groups = []
            }
            log.info("Loaded \(self.projects.count) projects, \(self.groups.count) groups")
        } catch {
            log.error("Failed to load projects.json: \(error.localizedDescription)")
        }
    }

    /// Schedules a debounced background write of the current state. Cheap to
    /// call repeatedly — bursts collapse into a single fsync. Called from
    /// every mutation method (the existing call sites still spell it `save`).
    private func save() {
        pendingSave?.cancel()
        let snapshot = StoreFile(version: 2, projects: projects, groups: groups)
        let url = storeURL
        let log = self.log
        let work = DispatchWorkItem {
            Self.write(snapshot, to: url, log: log)
        }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + saveDebounce, execute: work)
    }

    /// Synchronous write. Used from the app-quit path so changes inside the
    /// debounce window aren't dropped.
    func flushSync() {
        pendingSave?.cancel()
        pendingSave = nil
        Self.write(StoreFile(version: 2, projects: projects, groups: groups),
                   to: storeURL,
                   log: log)
    }

    private static func write(_ file: StoreFile, to url: URL, log: Logger) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(file)
            try data.write(to: url, options: [.atomic])
        } catch {
            log.error("Failed to save projects.json: \(error.localizedDescription)")
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([storeURL])
    }
}
