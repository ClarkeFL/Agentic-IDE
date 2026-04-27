import Foundation
import Observation
import OSLog

/// Maps Project.id to its in-memory ProjectSession. Sessions are created
/// lazily on first activation and retained for the rest of the app's lifetime
/// so terminals keep running across project switches.
///
/// Persistence: tab metadata (title, command, cwd, active id) is written to
/// `sessions.json` under Application Support. On the next launch the manager
/// restores the layout by re-spawning each tab's command — the live PTY
/// processes themselves don't survive an app exit.
@Observable
final class SessionManager {
    private let log = Logger(subsystem: "com.fabio.AgenticIDE", category: "SessionManager")

    private var sessions: [UUID: ProjectSession] = [:]
    private var pendingSnapshots: [UUID: SessionSnapshot] = [:]
    private let storeURL: URL

    init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil,
                                       create: true)) ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("AgenticIDE", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("sessions.json")
        loadSnapshots()
    }

    func session(for projectId: UUID) -> ProjectSession {
        if let existing = sessions[projectId] { return existing }
        let s = ProjectSession(projectId: projectId)
        sessions[projectId] = s

        if let snapshot = pendingSnapshots[projectId] {
            // Re-spawn each saved tab. New PIDs but the same logical tab.
            for tabSnap in snapshot.tabs {
                let cwd = tabSnap.workingDirectoryPath.map { URL(fileURLWithPath: $0) }
                let cfg = SurfaceConfig(command: tabSnap.command,
                                        workingDirectory: cwd,
                                        env: [:])
                let tab = TerminalTab(id: tabSnap.id, title: tabSnap.title, config: cfg)
                s.tabs.append(tab)
            }
            s.activeTabId = snapshot.activeTabId
            pendingSnapshots.removeValue(forKey: projectId)
        }

        // Install the save hook AFTER restore so the activeTabId assignment
        // above doesn't trigger a redundant write.
        s.saveHook = { [weak self] in self?.save() }
        // Wire smart-rename on every restored tab now that the save hook is
        // live (the rename closure calls markDirty → saveHook).
        for tab in s.tabs { s.wireSmartRename(tab) }
        return s
    }

    func discard(projectId: UUID) {
        sessions.removeValue(forKey: projectId)
        pendingSnapshots.removeValue(forKey: projectId)
        save()
    }

    // MARK: - Persistence

    /// Flushes the current state of every loaded session (plus any not-yet-
    /// activated pending snapshots) to disk. Called from ProjectSession's
    /// saveHook on every mutation.
    func save() {
        var all: [SessionSnapshot] = []
        for (projectId, session) in sessions {
            let tabs = session.tabs.map { tab in
                TabSnapshot(id: tab.id,
                            title: tab.title,
                            command: tab.command,
                            workingDirectoryPath: tab.workingDirectoryPath)
            }
            // Don't write empty sessions — they're equivalent to "not started".
            guard !tabs.isEmpty else { continue }
            all.append(SessionSnapshot(projectId: projectId,
                                       activeTabId: session.activeTabId,
                                       tabs: tabs))
        }
        // Preserve any snapshots we haven't restored yet (project never opened
        // in this run) so they survive next launch too.
        for (id, snap) in pendingSnapshots where !all.contains(where: { $0.projectId == id }) {
            all.append(snap)
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(all)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            log.error("Failed to save sessions.json: \(error.localizedDescription)")
        }
    }

    private func loadSnapshots() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let snapshots = try JSONDecoder().decode([SessionSnapshot].self, from: data)
            pendingSnapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.projectId, $0) })
            log.info("Loaded \(snapshots.count) project session(s) from disk")
        } catch {
            log.error("Failed to load sessions.json: \(error.localizedDescription)")
        }
    }
}

/// Per-project snapshot persisted to disk.
struct SessionSnapshot: Codable {
    var projectId: UUID
    var activeTabId: UUID?
    var tabs: [TabSnapshot]
}

/// Per-tab snapshot. Title + command + cwd is enough to recreate the surface.
struct TabSnapshot: Codable {
    var id: UUID
    var title: String
    var command: String?
    var workingDirectoryPath: String?
}
