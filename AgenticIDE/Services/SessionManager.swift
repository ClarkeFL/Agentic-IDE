import AppKit
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
    /// Serial queue used to encode + atomic-write sessions.json off the main
    /// thread. The hot path here is `markDirty()` from smart-rename, which
    /// fires on every Enter key in the terminal — debouncing + bg encode
    /// keeps that off the typing-latency budget.
    private let saveQueue = DispatchQueue(label: "com.fabio.AgenticIDE.SessionManager.save",
                                          qos: .utility)
    @ObservationIgnored
    private var pendingSave: DispatchWorkItem?
    /// Debounce window before the encode + write fires.
    private let saveDebounce: DispatchTimeInterval = .milliseconds(120)
    /// Hash of the most recently written blob. Skipped when the next snapshot
    /// hashes the same — most `markDirty()` calls reflect transient state
    /// changes that don't actually alter what we'd serialise.
    @ObservationIgnored
    private var lastWrittenHash: Int = 0
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
        self.storeURL = dir.appendingPathComponent("sessions.json")
        loadSnapshots()
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

    /// Schedules a debounced background write of the current state. Cheap to
    /// call — bursts of `markDirty()` from smart-rename collapse into one
    /// fsync, and snapshots that hash identical to the last write are
    /// skipped entirely.
    func save() {
        let snapshot = currentSnapshot()
        let hash = snapshot.contentHash
        // Skip if nothing the encoder would emit has changed. activeTabId
        // didSet still fires saveHook when tabs reshuffle (e.g. closeTab's
        // pre-removal active reassignment) but the persisted shape is the
        // same as what we'd write next tick.
        if hash == lastWrittenHash { return }

        pendingSave?.cancel()
        let url = storeURL
        let log = self.log
        let work = DispatchWorkItem { [weak self] in
            Self.write(snapshot, to: url, log: log)
            self?.lastWrittenHash = hash
        }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + saveDebounce, execute: work)
    }

    /// Synchronous flush of the current snapshot. Used from app-quit so any
    /// pending debounced write isn't dropped.
    func flushSync() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = currentSnapshot()
        Self.write(snapshot, to: storeURL, log: log)
        lastWrittenHash = snapshot.contentHash
    }

    private func currentSnapshot() -> [SessionSnapshot] {
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
        return all
    }

    private static func write(_ all: [SessionSnapshot], to url: URL, log: Logger) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(all)
            try data.write(to: url, options: [.atomic])
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

extension Array where Element == SessionSnapshot {
    /// Stable hash of the persisted shape. Used by `SessionManager.save()` to
    /// skip writes when a `markDirty()` call doesn't actually change anything
    /// the encoder would emit. Order-sensitive but the source dictionary
    /// iteration is stable enough for our purposes — a false miss just means
    /// one redundant write, never lost data.
    var contentHash: Int {
        var hasher = Hasher()
        for snap in self {
            hasher.combine(snap.projectId)
            hasher.combine(snap.activeTabId)
            hasher.combine(snap.tabs.count)
            for tab in snap.tabs {
                hasher.combine(tab.id)
                hasher.combine(tab.title)
                hasher.combine(tab.command)
                hasher.combine(tab.workingDirectoryPath)
            }
        }
        return hasher.finalize()
    }
}
