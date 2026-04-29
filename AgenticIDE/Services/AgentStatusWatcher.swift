import AppKit
import Foundation
import OSLog

/// File-system-backed bridge between agent hooks (Claude/Codex/etc.) and the
/// sidebar status indicator. Each terminal surface gets a stable UUID
/// (`tab.id`) which is exported as `AGENTIDE_SURFACE_ID` into its PTY env.
/// When an agent's hook fires, it writes the new status word to
/// `<status-dir>/<surface-id>`; this watcher picks the change up via a
/// DispatchSource on the directory and flips the matching `TerminalTab`'s
/// `status`.
///
/// Why a file watcher and not OSC/escape sequences:
///   - Hooks fire deterministically on agent lifecycle events (UserPromptSubmit,
///     Stop, …) — no parser to misread, no rendering chain to throttle.
///   - The file is updated even when the surface is occluded / its project
///     isn't active, so a "Working" indicator on a background tab is reliable.
///   - No bundled CLI / socket — `echo > file` is enough on the hook side.
final class AgentStatusWatcher {
    static let shared = AgentStatusWatcher()

    private let log = Logger(subsystem: "com.fabio.AgenticIDE", category: "AgentStatusWatcher")
    private let queue = DispatchQueue(label: "com.fabio.AgenticIDE.AgentStatusWatcher",
                                      qos: .utility)

    private let statusDir: URL
    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?

    /// Weak references — `TerminalTab` is `@Observable` and lives in
    /// `ProjectSession.tabs`. We don't want to extend its lifetime here.
    private final class WeakTab {
        weak var tab: TerminalTab?
        init(_ t: TerminalTab) { tab = t }
    }
    private var registry: [UUID: WeakTab] = [:]
    /// Per-file vnode watchers keyed by surface id. The directory source only
    /// fires when entries are added/removed; in-place writes (the hooks just
    /// truncate and re-write the existing file via shell `>` redirect) are
    /// invisible to it. Per-file sources catch those subsequent updates.
    private var fileSources: [UUID: FileSource] = [:]
    private let registryLock = NSLock()

    private final class FileSource {
        let fd: Int32
        let source: DispatchSourceFileSystemObject
        init(fd: Int32, source: DispatchSourceFileSystemObject) {
            self.fd = fd
            self.source = source
        }
    }

    /// Single source of truth for the directory hooks write to and we read
    /// from. Surfaced as a static so the hook installer can reference the
    /// same path when it constructs the shell command.
    static var statusDirectoryURL: URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true)) ?? fm.temporaryDirectory
        return appSupport
            .appendingPathComponent("AgenticIDE", isDirectory: true)
            .appendingPathComponent("status", isDirectory: true)
    }

    private init() {
        self.statusDir = Self.statusDirectoryURL
        try? FileManager.default.createDirectory(at: statusDir,
                                                 withIntermediateDirectories: true)
        startWatching()
    }

    deinit { stopWatching() }

    // MARK: - Tab registry

    func register(_ tab: TerminalTab) {
        registryLock.lock()
        registry[tab.id] = WeakTab(tab)
        registryLock.unlock()
        // Pick up any status the hook may have already written before this
        // tab was registered (e.g. respawn restoring an existing session),
        // and attach a per-file watcher so subsequent in-place hook writes
        // are caught even when the directory's NOTE_WRITE doesn't fire.
        queue.async { [weak self] in
            guard let self else { return }
            self.attachFileSourceIfNeeded(id: tab.id)
            self.scan()
        }
    }

    func unregister(id: UUID) {
        registryLock.lock()
        registry.removeValue(forKey: id)
        let removed = fileSources.removeValue(forKey: id)
        registryLock.unlock()
        // Cancel the per-file source first so its cancel handler can close
        // the fd before we unlink the file from the directory.
        removed?.source.cancel()
        // Best-effort cleanup so abandoned status files don't accumulate.
        let url = statusDir.appendingPathComponent(id.uuidString)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Watching

    private func startWatching() {
        let fd = open(statusDir.path, O_EVTONLY)
        guard fd >= 0 else {
            log.error("Failed to open status directory: \(self.statusDir.path, privacy: .public)")
            return
        }
        fileDescriptor = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 { close(self.fileDescriptor) }
            self.fileDescriptor = -1
        }
        src.resume()
        source = src
        log.info("Watching status directory: \(self.statusDir.path, privacy: .public)")
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
    }

    /// Off-main scan of the status directory. Reads each file whose name is
    /// a valid UUID (i.e. matches a known tab), parses the content, and
    /// dispatches the matching update to the main queue where `tab.status`
    /// can be mutated safely. Also attaches a per-file watcher for any newly
    /// discovered file — the directory event that brought us here only
    /// signalled "something appeared"; future in-place rewrites of that
    /// file won't echo through the directory source.
    private func scan() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: statusDir.path) else {
            return
        }

        var updates: [(UUID, TerminalTabStatus)] = []
        for name in names {
            guard let id = UUID(uuidString: name) else { continue }
            attachFileSourceIfNeeded(id: id)
            let url = statusDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let raw = String(data: data, encoding: .utf8)?
                              .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let status = TerminalTabStatus(hookWord: raw) else { continue }
            updates.append((id, status))
        }
        guard !updates.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for (id, status) in updates {
                self.registryLock.lock()
                let box = self.registry[id]
                self.registryLock.unlock()
                guard let tab = box?.tab else { continue }
                if tab.status != status {
                    self.log.debug("[\(tab.title, privacy: .public)] hook status → \(String(describing: status), privacy: .public)")
                    tab.status = status
                }
            }
        }
    }

    // MARK: - Per-file watching

    /// Open an `O_EVTONLY` fd on this surface's status file and watch it for
    /// in-place modifications. Idempotent and cheap: if the file doesn't
    /// exist yet (no hook has fired) or the tab isn't registered (orphan
    /// file), we simply skip — the directory source will trigger a re-scan
    /// once the file is created and we'll reattach then.
    ///
    /// Must be called from `queue` so the registry/fileSources mutation and
    /// `DispatchSource.resume()` happen serialised with `scan()`.
    private func attachFileSourceIfNeeded(id: UUID) {
        registryLock.lock()
        let isRegistered = registry[id] != nil
        let alreadyAttached = fileSources[id] != nil
        registryLock.unlock()
        guard isRegistered, !alreadyAttached else { return }

        let url = statusDir.appendingPathComponent(id.uuidString)
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self, weak src] in
            guard let self else { return }
            let flags = src?.data ?? []
            // If the file was unlinked (e.g. unregister cleanup) or renamed
            // out from under us, tear down. A future create will be picked
            // up by the directory source, which will reattach via `scan()`.
            if flags.contains(.delete) || flags.contains(.rename) {
                self.detachFileSource(id: id)
                return
            }
            self.readAndDispatch(id: id)
        }
        src.setCancelHandler {
            close(fd)
        }

        registryLock.lock()
        fileSources[id] = FileSource(fd: fd, source: src)
        registryLock.unlock()

        src.resume()
    }

    private func detachFileSource(id: UUID) {
        registryLock.lock()
        let removed = fileSources.removeValue(forKey: id)
        registryLock.unlock()
        removed?.source.cancel()
    }

    /// Reads a single status file (after a per-file event fires) and pushes
    /// the resulting status to the matching tab on the main queue.
    private func readAndDispatch(id: UUID) {
        let url = statusDir.appendingPathComponent(id.uuidString)
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8)?
                          .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let status = TerminalTabStatus(hookWord: raw) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.registryLock.lock()
            let box = self.registry[id]
            self.registryLock.unlock()
            guard let tab = box?.tab else { return }
            if tab.status != status {
                self.log.debug("[\(tab.title, privacy: .public)] hook status (file) → \(String(describing: status), privacy: .public)")
                tab.status = status
            }
        }
    }
}

extension TerminalTabStatus {
    /// Maps the hook-side status word to a `TerminalTabStatus`. The hook
    /// command writes one of these words via `printf` / `echo`; anything
    /// else is treated as unknown and the file is skipped.
    init?(hookWord raw: String) {
        switch raw {
        case "working": self = .working
        case "completed": self = .completed
        case "failed": self = .failed
        case "idle": self = .idle
        default: return nil
        }
    }
}
