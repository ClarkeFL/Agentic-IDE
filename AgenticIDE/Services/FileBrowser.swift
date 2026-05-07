import Foundation

/// One entry in the project file tree. Directories know whether they have
/// loaded their children yet (nil ≠ empty); files always have `children == nil`.
struct FileNode: Identifiable, Hashable {
    /// Full filesystem path — stable across rebuilds and used as a tree key.
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
}

/// Loader + filter for project files. Skips well-known noise dirs and
/// generated-package extensions so the tree stays useful on real repos
/// without needing a full `.gitignore` parser. Async, off-main, returns
/// alphabetised children with directories first.
enum FileBrowser {
    /// Names dropped wholesale. Conservative — only entries that are almost
    /// always generated/cache content, never user source.
    static let ignoredNames: Set<String> = [
        ".git", ".svn", ".hg", ".DS_Store",
        "node_modules", ".build", ".swiftpm",
        "DerivedData", "xcuserdata", "__pycache__",
        ".next", ".turbo", ".cache"
    ]

    /// Path-extension suffixes treated as opaque packages (so the user
    /// doesn't drill into `*.xcodeproj`'s pbxproj internals).
    static let ignoredExtensions: Set<String> = [
        "xcodeproj", "xcworkspace"
    ]

    static func shouldShow(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if ignoredNames.contains(name) { return false }
        if ignoredExtensions.contains(url.pathExtension) { return false }
        return true
    }

    /// Background-thread directory listing. Returns sorted nodes
    /// (directories first, alphabetical within each kind). Returns an
    /// empty array on permission / IO errors — callers can't usefully
    /// distinguish "empty dir" from "couldn't read", so we collapse both.
    static func list(_ url: URL) async -> [FileNode] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isDirectoryKey]
            guard let entries = try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: []
            ) else {
                return []
            }
            return entries
                .filter(shouldShow)
                .map { entry -> FileNode in
                    let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    return FileNode(
                        id: entry.path,
                        url: entry,
                        name: entry.lastPathComponent,
                        isDirectory: isDir
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
        }.value
    }
}
