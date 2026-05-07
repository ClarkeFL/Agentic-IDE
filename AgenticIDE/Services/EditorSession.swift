import AppKit
import Foundation
import Observation

/// In-memory state for the editor pane of one project: open tabs and which
/// one is focused. Created lazily by `EditorSessionManager` on first use,
/// retained for the rest of the app's lifetime so unsaved buffers survive
/// project switches.
@Observable
final class EditorSession: Identifiable {
    let projectId: UUID
    var tabs: [EditorTab] = []
    var activeTabId: UUID?

    init(projectId: UUID) {
        self.projectId = projectId
    }

    var activeTab: EditorTab? {
        guard let id = activeTabId else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    /// If `url` is already open, activate that tab. Otherwise create a new
    /// tab, schedule its initial disk read, and activate it. Skips
    /// directories — the file tree handles "open folder" by toggling
    /// expansion, the editor never opens a folder.
    @MainActor
    @discardableResult
    func open(_ url: URL) -> EditorTab? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else { return nil }

        if let existing = tabs.first(where: { $0.url == url }) {
            activeTabId = existing.id
            return existing
        }

        let tab = EditorTab(url: url)
        tabs.append(tab)
        activeTabId = tab.id
        Task { [weak self, weak tab] in
            await self?.load(tab: tab)
        }
        return tab
    }

    /// Close a tab. Caller is expected to have prompted the user about
    /// unsaved changes already — this just removes the entry. Returns the
    /// id of whatever became active afterwards (or nil if no tabs left).
    @MainActor
    @discardableResult
    func close(id: UUID) -> UUID? {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else {
            return activeTabId
        }
        let wasActive = (activeTabId == id)
        tabs.remove(at: idx)
        if wasActive {
            if tabs.isEmpty {
                activeTabId = nil
            } else {
                let newIdx = max(0, min(idx - 1, tabs.count - 1))
                activeTabId = tabs[newIdx].id
            }
        }
        return activeTabId
    }

    /// Lazily fetch the file's HEAD version for the diff view. No-op if
    /// already loaded (or already flagged as load-failed). Called from the
    /// editor pane the first time the user toggles diff mode for a tab.
    @MainActor
    func loadHeadIfNeeded(_ tab: EditorTab, projectRoot: URL) async {
        if tab.headText != nil || tab.headLoadFailed { return }
        let url = tab.url
        let result = await GitService.headContent(at: projectRoot, file: url)
        if let result {
            tab.headText = result
            tab.headLoadFailed = false
        } else {
            tab.headText = nil
            tab.headLoadFailed = true
        }
    }

    /// Persist the tab's buffer to its URL. Atomic write so a crash mid-save
    /// doesn't leave a half-written file. On success, mirrors `text` into
    /// `savedText` so `isDirty` flips false.
    @MainActor
    func save(_ tab: EditorTab) throws {
        let data = Data(tab.text.utf8)
        try data.write(to: tab.url, options: .atomic)
        tab.savedText = tab.text
        tab.loadError = nil
    }

    /// Notify any open tab that points at `oldURL` that its file has been
    /// renamed. Updates both the URL and the displayed filename. Doesn't
    /// touch the buffer — content didn't change, just the path.
    @MainActor
    func handleRename(from oldURL: URL, to newURL: URL) {
        guard let tab = tabs.first(where: { $0.url == oldURL }) else { return }
        tab.url = newURL
        tab.displayName = newURL.lastPathComponent
    }

    /// Notify any open tab that points at a deleted/moved-out-of-project
    /// path that its file is gone. Closes any tab whose URL is `url` itself
    /// or sits beneath `url` (so deleting a folder also closes every editor
    /// tab for files inside it). The tree's delete confirmation already
    /// covers the unsaved-changes warning.
    @MainActor
    func handleDeleted(_ url: URL) {
        let path = url.path
        let prefix = path + "/"
        let doomed = tabs.filter { tab in
            tab.url.path == path || tab.url.path.hasPrefix(prefix)
        }
        for tab in doomed { _ = close(id: tab.id) }
    }

    /// Notify any open tab that lives inside `oldRoot` that its parent has
    /// been moved (rename or drag-and-drop). Rewrites each tab's URL by
    /// swapping the prefix without touching the buffer.
    @MainActor
    func handleSubtreeMoved(from oldRoot: URL, to newRoot: URL) {
        let oldPath = oldRoot.path
        let oldPrefix = oldPath + "/"
        for tab in tabs {
            if tab.url.path == oldPath {
                tab.url = newRoot
                tab.displayName = newRoot.lastPathComponent
            } else if tab.url.path.hasPrefix(oldPrefix) {
                let suffix = String(tab.url.path.dropFirst(oldPrefix.count))
                let rebuilt = newRoot.appendingPathComponent(suffix)
                tab.url = rebuilt
                tab.displayName = rebuilt.lastPathComponent
            }
        }
    }

    /// Initial read for a freshly-opened tab. Caps at 16 MiB — we're a code
    /// editor, not a hex viewer, and trying to load a 200 MiB log into an
    /// `NSTextView` is a great way to wedge the UI for ten seconds. 16 MiB
    /// fits common large generated files (lockfiles, minified bundles).
    private static let maxBytes: Int = 16 * 1024 * 1024

    private func load(tab: EditorTab?) async {
        guard let tab else { return }
        let url = tab.url
        let result = await Task.detached(priority: .userInitiated) {
            () -> LoadResult in
            let fm = FileManager.default
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int else {
                return .ioError("Couldn't open file.")
            }
            if size > Self.maxBytes {
                let mb = Double(size) / (1024 * 1024)
                return .ioError(String(format: "File is %.1f MiB — too large to open in the editor.", mb))
            }
            guard let data = try? Data(contentsOf: url) else {
                return .ioError("Couldn't read file contents.")
            }
            // Empty files are valid text — open as a blank buffer rather
            // than tripping the binary / decode heuristics below.
            if data.isEmpty { return .text("") }

            // Files with NULs in the first 8 KiB are almost certainly
            // binary (executables, images, archives). We only sniff the
            // prefix because a few large legitimate text files (.po
            // translation files, some logs) can carry stray NULs deep in.
            let sniffWindow = data.prefix(8192)
            if sniffWindow.contains(0) { return .binary }

            // Try common text encodings in order of likelihood. UTF-8 is
            // the modern default; UTF-16 covers Windows-origin files;
            // Windows-1252 catches legacy Western-European text that
            // would otherwise fail UTF-8 validation.
            let encodings: [String.Encoding] = [.utf8, .utf16, .windowsCP1252, .isoLatin1]
            for enc in encodings {
                if let s = String(data: data, encoding: enc) {
                    return .text(s)
                }
            }
            return .binary
        }.value

        await MainActor.run {
            tab.didLoad = true
            switch result {
            case .text(let s):
                tab.text = s
                tab.savedText = s
                tab.isBinary = false
                tab.loadError = nil
            case .binary:
                tab.text = ""
                tab.savedText = ""
                tab.isBinary = true
                tab.loadError = nil
            case .ioError(let msg):
                tab.text = ""
                tab.savedText = ""
                tab.isBinary = false
                tab.loadError = msg
            }
        }
    }

    private enum LoadResult {
        case text(String)
        case binary
        case ioError(String)
    }
}

/// One `EditorSession` per project, lazily created. Mirrors
/// `SessionManager`'s shape so a project switch doesn't drop the user's
/// open editor tabs.
@Observable
final class EditorSessionManager {
    private var sessions: [UUID: EditorSession] = [:]

    func session(for projectId: UUID) -> EditorSession {
        if let s = sessions[projectId] { return s }
        let s = EditorSession(projectId: projectId)
        sessions[projectId] = s
        return s
    }

    /// Drop a session entirely (e.g. project archived/deleted).
    func discard(projectId: UUID) {
        sessions.removeValue(forKey: projectId)
    }
}
