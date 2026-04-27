import AppKit
import Foundation
import Observation
import OSLog

/// Loads and saves the user's projects list. Backed by a single JSON file at
/// `~/Library/Application Support/AgenticIDE/projects.json`. Atomic writes.
@Observable
final class ProjectStore {
    private let log = Logger(subsystem: "com.fabio.AgenticIDE", category: "ProjectStore")

    private(set) var projects: [Project] = []

    private let storeURL: URL

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
    }

    // MARK: - Mutations

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

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            projects = try decoder.decode([Project].self, from: data)
            log.info("Loaded \(self.projects.count) projects")
        } catch {
            log.error("Failed to load projects.json: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(projects)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            log.error("Failed to save projects.json: \(error.localizedDescription)")
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([storeURL])
    }
}
