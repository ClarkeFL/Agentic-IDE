import AppKit
import Foundation
import Observation
import OSLog

/// Maps Project.id to its in-memory ProjectSession. Sessions are created
/// lazily on first activation and retained for the rest of the app's lifetime
/// so terminals keep running across project switches.
///
/// Persistence: workspace + cell metadata (grid size, per-cell command/title/
/// cwd) is written to `sessions.json` under Application Support. On the next
/// launch the manager rebuilds each workspace and re-spawns each cell's
/// command — the live PTY processes themselves don't survive an app exit.
///
/// Migration: this build introduced workspaces. An old `sessions.json` (a flat
/// `[{tabs:[…]}]` array) no longer decodes into the new shape; `loadSnapshots`
/// treats that as "no saved state" and starts fresh, overwriting on first save.
@Observable
final class SessionManager {
    private let log = Logger(subsystem: "com.fabio.AgenticIDE", category: "SessionManager")

    private var sessions: [UUID: ProjectSession] = [:]
    private var pendingSnapshots: [UUID: SessionSnapshot] = [:]
    @ObservationIgnored
    private var restoringProjectIds: Set<UUID> = []
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

        s.saveHook = { [weak self] in self?.save() }
        // No auto-seed: a project with no saved workspaces stays empty, and
        // pane ④ shows the layout chooser until the user picks a grid size.
        scheduleRestoreIfNeeded(projectId: projectId, into: s)
        return s
    }

    private func scheduleRestoreIfNeeded(projectId: UUID, into session: ProjectSession) {
        guard let snapshot = pendingSnapshots[projectId],
              !restoringProjectIds.contains(projectId) else { return }
        restoringProjectIds.insert(projectId)

        DispatchQueue.main.async { [weak self, weak session] in
            guard let self, let session else { return }
            guard self.pendingSnapshots[projectId]?.projectId == snapshot.projectId else {
                self.restoringProjectIds.remove(projectId)
                return
            }

            for wsSnap in snapshot.workspaces {
                let cells: [WorkspaceCell] = wsSnap.cells.map { cellSnap in
                    let cell = WorkspaceCell(id: cellSnap.id, icon: cellSnap.icon)
                    if let command = cellSnap.command {
                        let cwd = cellSnap.workingDirectoryPath.map { URL(fileURLWithPath: $0) }
                        let cfg = SurfaceConfig(
                            command: PtyService.commandEnsuringTerminalBootstrap(command),
                            workingDirectory: cwd,
                            env: PtyService.terminalEnvironment())
                        let tab = TerminalTab(id: cellSnap.id,
                                              title: cellSnap.title ?? "Terminal",
                                              config: cfg)
                        session.wireSmartRename(tab)
                        cell.terminal = tab
                    }
                    return cell
                }
                let ws = Workspace(id: wsSnap.id,
                                   name: wsSnap.name,
                                   layout: wsSnap.gridLayout,
                                   cells: cells)
                session.workspaces.append(ws)
            }
            session.activeWorkspaceId = snapshot.activeWorkspaceId ?? session.workspaces.first?.id
            self.pendingSnapshots.removeValue(forKey: projectId)
            self.restoringProjectIds.remove(projectId)
        }
    }

    /// Returns an already-restored live session without materialising one from
    /// a saved snapshot. Sidebar rows use this so drawing the project list
    /// doesn't accidentally spawn terminals for every saved project.
    func liveSession(for projectId: UUID) -> ProjectSession? {
        sessions[projectId]
    }

    /// The session + workspace whose grid contains a cell running the terminal
    /// with this surface id. Used by the agent bridge to resolve "which cells
    /// can the caller address / modify" — scoped to its own workspace.
    func locate(surfaceId id: UUID) -> (session: ProjectSession, workspace: Workspace)? {
        for (_, session) in sessions {
            for ws in session.workspaces
            where ws.cells.contains(where: { $0.terminal?.id == id }) {
                return (session, ws)
            }
        }
        return nil
    }

    /// Cheap persisted workspace count for projects that haven't been activated
    /// in this run yet. Does not restore or spawn any terminal surfaces.
    func savedWorkspaceCount(for projectId: UUID) -> Int {
        pendingSnapshots[projectId]?.workspaces.count ?? 0
    }

    func discard(projectId: UUID) {
        sessions.removeValue(forKey: projectId)
        pendingSnapshots.removeValue(forKey: projectId)
        save()
    }

    // MARK: - Persistence

    /// Schedules a debounced background write of the current state. Cheap to
    /// call — bursts of `markDirty()` from smart-rename collapse into one
    /// fsync, and snapshots that hash identical to the last write are skipped.
    func save() {
        let snapshot = currentSnapshot()
        let hash = snapshot.contentHash
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
            guard Self.isPersistWorthy(session) else { continue }
            let workspaces = session.workspaces.map { ws in
                WorkspaceSnapshot(
                    id: ws.id,
                    name: ws.name,
                    axis: ws.axis.rawValue,
                    counts: ws.counts,
                    cells: ws.cells.map { cell in
                        CellSnapshot(id: cell.id,
                                     icon: cell.icon,
                                     command: cell.terminal?.command,
                                     title: cell.terminal?.title,
                                     workingDirectoryPath: cell.terminal?.workingDirectoryPath)
                    })
            }
            all.append(SessionSnapshot(projectId: projectId,
                                       activeWorkspaceId: session.activeWorkspaceId,
                                       workspaces: workspaces))
        }
        // Preserve any snapshots we haven't restored yet (project never opened
        // in this run) so they survive next launch too.
        for (id, snap) in pendingSnapshots where !all.contains(where: { $0.projectId == id }) {
            all.append(snap)
        }
        return all
    }

    /// Persist any project the user has set up at least one workspace for.
    /// Projects that were only browsed (no workspace created) stay unsaved, so
    /// next launch they show the layout chooser instead of a restored grid.
    private static func isPersistWorthy(_ session: ProjectSession) -> Bool {
        !session.workspaces.isEmpty
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
            // Most likely an old (pre-workspaces) sessions.json. Start fresh —
            // the first save overwrites it with the new shape.
            log.info("No compatible sessions.json (\(error.localizedDescription)); starting fresh")
        }
    }
}

/// Per-project snapshot persisted to disk.
struct SessionSnapshot: Codable {
    var projectId: UUID
    var activeWorkspaceId: UUID?
    var workspaces: [WorkspaceSnapshot]
}

/// Per-workspace snapshot: grid shape + cells. `axis`/`counts` describe the
/// (possibly uneven) layout; the legacy `rows`/`cols` are still read so
/// pre-existing `sessions.json` files restore as a uniform grid. Any
/// `outerWeights`/`innerWeights` from old files are simply ignored on decode.
struct WorkspaceSnapshot: Codable {
    var id: UUID
    var name: String
    var axis: String?
    var counts: [Int]?
    // Legacy (pre-uneven-layouts) fields, read-only.
    var rows: Int?
    var cols: Int?
    var cells: [CellSnapshot]

    /// The layout to restore: prefer the new axis/counts, else fall back to the
    /// legacy rows×cols rectangle, else a single cell.
    var gridLayout: GridLayout {
        if let axis, let a = LayoutAxis(rawValue: axis), let counts, !counts.isEmpty {
            return GridLayout(axis: a, counts: counts)
        }
        if let rows, let cols {
            return GridLayout(axis: .rows, counts: Array(repeating: cols, count: max(1, rows)))
        }
        return GridLayout(axis: .rows, counts: [1])
    }
}

/// Per-cell snapshot. Command + cwd is enough to re-spawn the surface; kind +
/// title keep the cell labelled before the process prints anything.
struct CellSnapshot: Codable {
    var id: UUID
    var icon: String?
    var command: String?
    var title: String?
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
            hasher.combine(snap.activeWorkspaceId)
            hasher.combine(snap.workspaces.count)
            for ws in snap.workspaces {
                hasher.combine(ws.id)
                hasher.combine(ws.name)
                hasher.combine(ws.axis)
                hasher.combine(ws.counts)
                for cell in ws.cells {
                    hasher.combine(cell.id)
                    hasher.combine(cell.icon)
                    hasher.combine(cell.command)
                    hasher.combine(cell.title)
                    hasher.combine(cell.workingDirectoryPath)
                }
            }
        }
        return hasher.finalize()
    }
}
