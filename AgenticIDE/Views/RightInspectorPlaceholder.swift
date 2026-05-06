import AppKit
import SwiftUI

/// Right column: a two-mode inspector. **Changes** shows git status (top)
/// + the unified diff for the selected file (bottom), polled every 5 s while
/// the window is on screen (paused when the app is inactive or fully
/// occluded). **Files** shows the project's file tree (top) + a text preview
/// of the selected file (bottom), loaded lazily per directory. The mode
/// toggle lives in the header. There's no UI for staging — the spec is
/// explicit about diff *view* only; use a terminal tab for any git command.
struct RightInspectorView: View {
    let project: Project?

    @State private var mode: InspectorMode = .changes

    // Changes-mode state
    @State private var changes: [GitChange] = []
    @State private var selectedFile: URL?
    @State private var isStatusUnavailable: Bool = false
    @State private var diffText: String = ""
    @State private var isLoadingDiff: Bool = false
    /// Whether the app currently has any visible (non-occluded) window.
    /// Driven by `NSApplication.didChangeOcclusionStateNotification`. When
    /// false the git-status poll pauses so a hidden window stops shelling
    /// out twice per status interval.
    @State private var isAppVisible: Bool = NSApp?.occlusionState.contains(.visible) ?? true
    @Environment(\.scenePhase) private var scenePhase

    // Files-mode state — kept separate so flipping modes doesn't trample
    // either pane's selection.
    @State private var selectedProjectFile: URL?
    /// Bumped manually to force the file-tree view to re-walk the root.
    @State private var filesRefreshToken: Int = 0

    /// Whether the inspector should run its expensive periodic work (git
    /// status). False when the app is inactive or fully occluded.
    private var pollingEnabled: Bool {
        scenePhase == .active && isAppVisible
    }

    var body: some View {
        // `InspectorHeader` owns its own trailing divider so the three
        // column headers (sidebar, workspace, inspector) draw their
        // dividers at the same y-coordinate.
        VStack(spacing: 0) {
            header
            if let project {
                content(for: project)
            } else {
                emptyProjectState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        // Reset per-project state on switch — done via .onChange so
        // visibility flips don't clear the stored changeset.
        .onChange(of: project?.id) { _, _ in
            changes = []
            selectedFile = nil
            diffText = ""
            isStatusUnavailable = false
        }
        // Polling task. Composite id restarts the loop on project switch
        // and on visibility changes (active + non-occluded), and cancels
        // it on disappear.
        .task(id: PollingKey(projectId: project?.id, enabled: pollingEnabled)) {
            await runStatusPoll()
        }
        // Running the diff fetch as a `.task(id:)` lets SwiftUI cancel an
        // in-flight refresh when the user picks a different file —
        // otherwise a slow `git diff` from selection N could land after
        // selection N+1 and overwrite the pane with stale content.
        .task(id: selectedFile) {
            await refreshDiff(for: selectedFile)
        }
        .onChange(of: changes) { _, _ in
            // If the selected file disappears from the change list (user
            // committed or reverted), clear the diff pane.
            guard let sel = selectedFile else { return }
            if !changes.contains(where: { $0.url == sel }) {
                selectedFile = nil
                diffText = ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeOcclusionStateNotification
        )) { _ in
            isAppVisible = NSApp?.occlusionState.contains(.visible) ?? true
        }
    }

    /// Composite key that drives `.task(id:)` for the status poll. The poll
    /// task restarts when the project changes (so the per-project reset
    /// runs from a known idle state) or when the app's visibility flips —
    /// flipping `enabled` from false → true resumes polling immediately
    /// instead of waiting out the previous sleep.
    private struct PollingKey: Hashable {
        let projectId: UUID?
        let enabled: Bool
    }

    // MARK: - Subviews

    @ViewBuilder
    private func content(for project: Project) -> some View {
        switch mode {
        case .changes:
            ChangedFilesList(
                changes: changes,
                selectedFile: $selectedFile,
                isStatusUnavailable: isStatusUnavailable,
                projectPath: project.path
            )
            .frame(minHeight: 100, idealHeight: 220)
            Divider()
            diffSection(project: project)
                .frame(maxHeight: .infinity)
        case .files:
            ProjectFilesList(projectPath: project.path,
                             selectedFile: $selectedProjectFile,
                             refreshToken: filesRefreshToken)
                .frame(minHeight: 100, idealHeight: 220)
            Divider()
            FilePreviewPane(file: selectedProjectFile)
                .frame(maxHeight: .infinity)
        }
    }

    private var currentOpenTarget: URL? {
        switch mode {
        case .files: return selectedProjectFile ?? project?.path
        case .changes: return selectedFile ?? project?.path
        }
    }

    private var header: some View {
        InspectorHeader(
            mode: $mode,
            changeCount: changes.count,
            isRefreshDisabled: project == nil,
            onRefresh: {
                switch mode {
                case .changes: Task { await refreshStatusOnce() }
                case .files:   filesRefreshToken &+= 1
                }
            },
            openTarget: currentOpenTarget
        )
    }

    private var diffHeader: DiffHeader? {
        guard let file = selectedFile,
              let change = changes.first(where: { $0.url == file }) else { return nil }
        return DiffHeader(displayName: change.displayName,
                          directory: change.directoryName,
                          status: change.status,
                          stateSubtitle: change.stateSubtitle)
    }

    @ViewBuilder
    private func diffSection(project: Project) -> some View {
        let placeholder: String = {
            if changes.isEmpty {
                return isStatusUnavailable
                    ? "Not a git repository.\nOpen a terminal tab and run `git init` to start tracking."
                    : "No uncommitted changes."
            }
            if selectedFile == nil { return "Select a file above to view its diff." }
            return "No diff to show for this file."
        }()
        GitDiffView(diffText: diffText,
                    isLoading: isLoadingDiff,
                    placeholder: placeholder,
                    header: diffHeader)
    }

    private var emptyProjectState: some View {
        VStack(spacing: DS.Space.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: DS.Icon.display, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No project selected")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status polling

    /// Drives a 5-second poll for `git status` while the inspector is on
    /// screen, the app is active, and the window isn't fully occluded.
    /// Cancelled on disappear / project switch / visibility change via
    /// `.task(id:)` semantics.
    private func runStatusPoll() async {
        guard project != nil else { return }
        guard pollingEnabled else { return }
        await refreshStatusOnce()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { break }
            await refreshStatusOnce()
        }
    }

    private func refreshStatusOnce() async {
        guard let project else { return }
        let result = await GitService.status(at: project.path)
        await MainActor.run {
            if let result {
                isStatusUnavailable = false
                if changes != result { changes = result }
            } else {
                isStatusUnavailable = true
                if !changes.isEmpty { changes = [] }
            }
        }
    }

    private func refreshDiff(for file: URL?) async {
        guard let project, let file else {
            await MainActor.run { diffText = "" }
            return
        }
        let isUntracked = changes.first(where: { $0.url == file })?.status == .untracked
        await MainActor.run { isLoadingDiff = true }
        let text = await GitService.diff(at: project.path,
                                         file: file,
                                         isUntracked: isUntracked)
        await MainActor.run {
            // Drop "diff --no-index" header noise for untracked files so the
            // user sees just `+` lines for the file content.
            diffText = text
            isLoadingDiff = false
        }
    }
}

// Inspector layout metrics now live in `DesignTokens.swift` (DS.Gutter,
// DS.Tree, DS.Control). Removing the local enums forces every reader to
// consume the app-wide tokens — no more drift between this file and the
// rest of the chrome.

// MARK: - Changed files tree

/// One node in the changes tree. Either a directory (no `change`, has
/// `children`) or a file leaf (has `change`, `children == nil`).
private struct ChangeNode: Identifiable, Hashable {
    let id: String          // full relative path, used for OutlineGroup identity
    let name: String        // last segment (or compacted "Models/Sub")
    let change: GitChange?  // non-nil only for file leaves
    var children: [ChangeNode]?

    var isDirectory: Bool { change == nil }
}

/// Builds a nested tree from a flat list of changes, then collapses any
/// directory chain that has only a single sub-directory child (so a
/// changeset that hugs `AgenticIDE/Models/...` doesn't force the user
/// through three click-to-expands).
private enum ChangeTree {
    final class MutableNode {
        var name: String
        var fullPath: String
        var change: GitChange?
        var children: [String: MutableNode] = [:]
        init(name: String, fullPath: String) {
            self.name = name
            self.fullPath = fullPath
        }
    }

    static func build(from changes: [GitChange]) -> [ChangeNode] {
        let root = MutableNode(name: "", fullPath: "")
        for change in changes {
            let parts = change.relativePath.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            var current = root
            var pathSoFar = ""
            for (i, part) in parts.enumerated() {
                pathSoFar = pathSoFar.isEmpty ? part : "\(pathSoFar)/\(part)"
                if let existing = current.children[part] {
                    current = existing
                } else {
                    let node = MutableNode(name: part, fullPath: pathSoFar)
                    current.children[part] = node
                    current = node
                }
                if i == parts.count - 1 {
                    current.change = change
                }
            }
        }
        return root.children.values
            .map { freeze(compactChain($0)) }
            .sorted(by: nodeOrder)
    }

    /// Folds a directory with a single sub-directory child into the child,
    /// concatenating names with "/". Stops as soon as the chain branches
    /// or hits a leaf. File entries are left untouched.
    private static func compactChain(_ node: MutableNode) -> MutableNode {
        for key in node.children.keys {
            node.children[key] = compactChain(node.children[key]!)
        }
        while node.change == nil,
              node.children.count == 1,
              let only = node.children.values.first,
              only.change == nil {
            node.name = "\(node.name)/\(only.name)"
            node.fullPath = only.fullPath
            node.children = only.children
        }
        return node
    }

    private static func freeze(_ node: MutableNode) -> ChangeNode {
        let kids = node.children.values
            .map { freeze($0) }
            .sorted(by: nodeOrder)
        return ChangeNode(
            id: node.fullPath,
            name: node.name,
            change: node.change,
            children: kids.isEmpty ? nil : kids
        )
    }

    /// Directories first, alphabetical within each kind.
    private static func nodeOrder(_ lhs: ChangeNode, _ rhs: ChangeNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

/// Flat row representation of the tree. Computed by walking `roots` and
/// dropping the children of any directory whose id is in `collapsed`.
/// Driving the List with this flat list (instead of nested DisclosureGroup)
/// gives clean row insertion / removal animation with no fade-through.
private struct TreeRow: Identifiable, Hashable {
    let node: ChangeNode
    let depth: Int
    var id: String { node.id }
}

private struct ChangedFilesList: View {
    let changes: [GitChange]
    @Binding var selectedFile: URL?
    let isStatusUnavailable: Bool
    let projectPath: URL

    /// Path-string ids of directories the user has collapsed. Empty by
    /// default → everything expanded so the full changeset is visible
    /// the moment the inspector opens.
    @State private var collapsed: Set<String> = []
    /// Memoised tree. Rebuilt only when `changes` actually changes; a
    /// computed property would re-walk the input on every body redraw.
    @State private var roots: [ChangeNode] = []
    /// Memoised flat row list. Rebuilt when `roots` or `collapsed` change.
    @State private var visibleRows: [TreeRow] = []

    var body: some View {
        Group {
            if isStatusUnavailable {
                centered("Not a git repository", systemImage: "questionmark.folder")
            } else if changes.isEmpty {
                centered("Working tree clean", systemImage: "checkmark.circle")
            } else {
                List(selection: $selectedFile) {
                    ForEach(visibleRows) { row in
                        rowView(for: row)
                            .listRowInsets(EdgeInsets(top: 1,
                                                      leading: DS.Gutter.inspector,
                                                      bottom: 1,
                                                      trailing: DS.Gutter.inspectorTrailing))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
                .padding(.top, DS.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            roots = ChangeTree.build(from: changes)
            rebuildVisibleRows()
        }
        .onChange(of: changes) { _, new in
            roots = ChangeTree.build(from: new)
            rebuildVisibleRows()
        }
        .onChange(of: collapsed) { _, _ in
            rebuildVisibleRows()
        }
    }

    @ViewBuilder
    private func rowView(for row: TreeRow) -> some View {
        if let change = row.node.change {
            ChangedFileRow(change: change, depth: row.depth)
                .tag(change.url)
        } else {
            DirectoryRow(node: row.node,
                         depth: row.depth,
                         isExpanded: !collapsed.contains(row.node.id),
                         toggle: { toggle(row.node.id) })
        }
    }

    /// Tree-walk that respects the current collapsed set. Writes results to
    /// `visibleRows` State so SwiftUI doesn't re-walk on every body redraw.
    private func rebuildVisibleRows() {
        var result: [TreeRow] = []
        result.reserveCapacity(changes.count + roots.count)
        func walk(_ nodes: [ChangeNode], depth: Int) {
            for node in nodes {
                result.append(TreeRow(node: node, depth: depth))
                if node.isDirectory,
                   !collapsed.contains(node.id),
                   let kids = node.children {
                    walk(kids, depth: depth + 1)
                }
            }
        }
        walk(roots, depth: 0)
        visibleRows = result
    }

    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if collapsed.contains(id) {
                collapsed.remove(id)
            } else {
                collapsed.insert(id)
            }
        }
    }

    private func centered(_ text: String, systemImage: String) -> some View {
        VStack(spacing: DS.Space.sm) {
            Image(systemName: systemImage)
                .font(.system(size: DS.Icon.large, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// Directory header row. Renders a chevron that rotates 90° between
/// collapsed and expanded, with the directory name uppercase to match the
/// section-header look. Whole row is the click target.
private struct DirectoryRow: View {
    let node: ChangeNode
    let depth: Int
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 0) {
                Color.clear.frame(width: CGFloat(depth) * DS.Tree.indentStep)
                Image(systemName: "chevron.right")
                    .font(.system(size: DS.Icon.micro, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: DS.Tree.chevronColumn, alignment: .leading)
                Text(node.name)
                    .font(DS.Font.sectionCaps)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, DS.Space.xxs)
    }
}

/// Compact single-line file row. Status indicator at the leading edge, name
/// in the middle, +/- stats trailing. Stage state lives in the tooltip and
/// in the diff-view header — duplicating it as a second line was the main
/// source of vertical bloat.
private struct ChangedFileRow: View {
    let change: GitChange
    let depth: Int

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Color.clear.frame(width: CGFloat(depth) * DS.Tree.indentStep + DS.Tree.chevronColumn)
            StatusBadge(status: change.status, size: 13)
                // Outline-only when fully staged (nothing further to commit
                // from working tree); filled while there are still unstaged
                // edits. Subtle but reads at a glance.
                .opacity(change.stageState == .staged ? 0.55 : 1.0)
            Text(change.displayName)
                .font(DS.Font.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DS.Space.sm)
            stats
        }
        .padding(.vertical, DS.Space.xs)
        .help("\(change.stateSubtitle) — \(change.relativePath)")
    }

    @ViewBuilder
    private var stats: some View {
        if change.additions > 0 || change.deletions > 0 {
            HStack(spacing: DS.Space.xs) {
                if change.additions > 0 {
                    Text("+\(change.additions)")
                        .foregroundStyle(Color(red: 0.22, green: 0.78, blue: 0.45))
                }
                if change.deletions > 0 {
                    Text("−\(change.deletions)")
                        .foregroundStyle(Color(red: 0.90, green: 0.30, blue: 0.30))
                }
            }
            .font(DS.Font.stats)
        }
    }
}

// MARK: - Inspector mode

enum InspectorMode: Hashable {
    case files
    case changes
}

// MARK: - File tree

/// One entry in the project file tree. Directories know whether they have
/// loaded their children yet (nil ≠ empty); files always have `children == nil`.
private struct FileNode: Identifiable, Hashable {
    let id: String           // full filesystem path — stable across rebuilds
    let url: URL
    let name: String
    let isDirectory: Bool
}

/// Loader + filter for project files. Skips well-known noise dirs and
/// generated-package extensions so the tree stays useful on real repos
/// without needing a full `.gitignore` parser.
private enum FileBrowser {
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

private struct FileTreeRow: Identifiable, Hashable {
    let node: FileNode
    let depth: Int
    var id: String { node.id }
}

/// Lazy-loading file tree. Root is fetched on appear / project change;
/// child directories are fetched the first time they're expanded and then
/// cached. Mirrors `ChangedFilesList`'s flat-rows-from-collapsed-set
/// pattern so animations and keyboard navigation feel identical.
private struct ProjectFilesList: View {
    let projectPath: URL
    @Binding var selectedFile: URL?
    /// Bumped by the inspector header's refresh button — invalidates the
    /// cache and re-walks the root.
    let refreshToken: Int

    @State private var rootNodes: [FileNode] = []
    @State private var childrenCache: [String: [FileNode]] = [:]
    @State private var expanded: Set<String> = []
    @State private var loading: Set<String> = []
    @State private var isLoadingRoot: Bool = false
    @State private var visibleRows: [FileTreeRow] = []

    var body: some View {
        Group {
            if isLoadingRoot && rootNodes.isEmpty {
                centered("Loading…", systemImage: "folder")
            } else if rootNodes.isEmpty {
                centered("Folder is empty", systemImage: "folder")
            } else {
                List(selection: $selectedFile) {
                    ForEach(visibleRows) { row in
                        rowView(for: row)
                            .listRowInsets(EdgeInsets(top: 1,
                                                      leading: DS.Gutter.inspector,
                                                      bottom: 1,
                                                      trailing: DS.Gutter.inspectorTrailing))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
                .padding(.top, DS.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: TaskKey(path: projectPath, token: refreshToken)) {
            await loadRoot()
        }
        .onChange(of: rootNodes) { _, _ in rebuildVisibleRows() }
        .onChange(of: expanded) { _, _ in rebuildVisibleRows() }
        .onChange(of: childrenCache) { _, _ in rebuildVisibleRows() }
    }

    /// Composite id so `.task(id:)` re-fires when either the project path
    /// changes (project switch) OR the manual refresh token bumps.
    private struct TaskKey: Hashable {
        let path: URL
        let token: Int
    }

    @ViewBuilder
    private func rowView(for row: FileTreeRow) -> some View {
        if row.node.isDirectory {
            FileDirectoryRow(
                node: row.node,
                depth: row.depth,
                isExpanded: expanded.contains(row.node.id),
                isLoading: loading.contains(row.node.id),
                toggle: { toggle(row.node) }
            )
        } else {
            FileLeafRow(node: row.node, depth: row.depth)
                .tag(row.node.url)
        }
    }

    // MARK: - State updates

    private func loadRoot() async {
        await MainActor.run {
            isLoadingRoot = true
            childrenCache = [:]
            loading = []
        }
        let nodes = await FileBrowser.list(projectPath)
        await MainActor.run {
            rootNodes = nodes
            isLoadingRoot = false
        }
    }

    private func toggle(_ node: FileNode) {
        if expanded.contains(node.id) {
            withAnimation(.easeInOut(duration: 0.18)) {
                _ = expanded.remove(node.id)
            }
            return
        }
        // Expand. If we haven't loaded this directory yet, kick off a load
        // and only insert into `expanded` once the children are in the
        // cache — keeps the row from flashing "empty" on slow disks.
        if childrenCache[node.id] != nil {
            withAnimation(.easeInOut(duration: 0.18)) {
                _ = expanded.insert(node.id)
            }
            return
        }
        loading.insert(node.id)
        Task {
            let children = await FileBrowser.list(node.url)
            await MainActor.run {
                childrenCache[node.id] = children
                loading.remove(node.id)
                withAnimation(.easeInOut(duration: 0.18)) {
                    _ = expanded.insert(node.id)
                }
            }
        }
    }

    private func rebuildVisibleRows() {
        var result: [FileTreeRow] = []
        result.reserveCapacity(rootNodes.count)
        func walk(_ nodes: [FileNode], depth: Int) {
            for node in nodes {
                result.append(FileTreeRow(node: node, depth: depth))
                if node.isDirectory,
                   expanded.contains(node.id),
                   let kids = childrenCache[node.id] {
                    walk(kids, depth: depth + 1)
                }
            }
        }
        walk(rootNodes, depth: 0)
        visibleRows = result
    }

    private func centered(_ text: String, systemImage: String) -> some View {
        VStack(spacing: DS.Space.sm) {
            Image(systemName: systemImage)
                .font(.system(size: DS.Icon.large, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct FileDirectoryRow: View {
    let node: FileNode
    let depth: Int
    let isExpanded: Bool
    let isLoading: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 0) {
                Color.clear.frame(width: CGFloat(depth) * DS.Tree.indentStep)
                Group {
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.55)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: DS.Icon.micro, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .frame(width: DS.Tree.chevronColumn, alignment: .leading)
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(DS.Font.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: DS.Tree.iconColumn, alignment: .leading)
                Text(node.name)
                    .font(DS.Font.bodyMedium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, DS.Space.xxs)
    }
}

private struct FileLeafRow: View {
    let node: FileNode
    let depth: Int

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(depth) * DS.Tree.indentStep + DS.Tree.chevronColumn)
            Image(systemName: "doc")
                .font(DS.Font.footnote)
                .foregroundStyle(.secondary)
                .frame(width: DS.Tree.iconColumn, alignment: .leading)
            Text(node.name)
                .font(DS.Font.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.Space.xs)
        .help(node.url.path)
    }
}

// MARK: - File preview

/// Bottom pane for Files mode. Reads up to `maxBytes` of the selected file
/// and renders as monospace text. Refuses anything that doesn't decode as
/// UTF-8 (treated as binary) and anything bigger than the cap (treated as
/// "open externally"). The 512KB cap matches what most editors use as the
/// "this might be a generated file, syntax-highlight cautiously" threshold.
private struct FilePreviewPane: View {
    let file: URL?

    private nonisolated static let maxBytes: Int = 512 * 1024

    @State private var content: String = ""
    @State private var state: PreviewState = .empty
    @State private var loadedFile: URL?

    private enum PreviewState: Equatable {
        case empty
        case loading
        case text
        case binary
        case tooLarge(Int)
        case ioError
    }

    var body: some View {
        Group {
            switch state {
            case .empty:
                placeholder("Select a file above to view its contents.",
                            systemImage: "doc.text")
            case .loading:
                VStack(spacing: DS.Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .text:
                ScrollView([.vertical, .horizontal], showsIndicators: true) {
                    Text(content)
                        .font(DS.Font.codeBody)
                        .textSelection(.enabled)
                        .padding(.leading, DS.Gutter.inspector)
                        .padding(.trailing, DS.Gutter.inspectorTrailing)
                        .padding(.vertical, DS.Space.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
            case .binary:
                placeholder("Binary file — preview not available.",
                            systemImage: "doc.zipper")
            case .tooLarge(let bytes):
                placeholder("File is \(formatBytes(bytes)) — too large to preview.",
                            systemImage: "doc.text.magnifyingglass")
            case .ioError:
                placeholder("Couldn't read this file.",
                            systemImage: "exclamationmark.triangle")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: file) {
            await load(file)
        }
    }

    private func placeholder(_ text: String, systemImage: String) -> some View {
        VStack(spacing: DS.Space.sm) {
            Image(systemName: systemImage)
                .font(.system(size: DS.Icon.large, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.xxl)
    }

    private func load(_ url: URL?) async {
        guard let url else {
            await MainActor.run {
                state = .empty
                content = ""
                loadedFile = nil
            }
            return
        }
        if loadedFile == url, state != .empty { return }
        await MainActor.run { state = .loading }
        let result = await Self.read(url)
        await MainActor.run {
            loadedFile = url
            switch result {
            case .text(let s):
                content = s
                state = .text
            case .binary:
                content = ""
                state = .binary
            case .tooLarge(let bytes):
                content = ""
                state = .tooLarge(bytes)
            case .ioError:
                content = ""
                state = .ioError
            }
        }
    }

    private enum ReadResult {
        case text(String)
        case binary
        case tooLarge(Int)
        case ioError
    }

    private static func read(_ url: URL) async -> ReadResult {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int else {
                return ReadResult.ioError
            }
            if size > maxBytes { return .tooLarge(size) }
            guard let data = try? Data(contentsOf: url) else { return .ioError }
            // Reject anything with embedded NULs — fastest cheap heuristic
            // for "binary" before paying for a UTF-8 decode attempt.
            if data.contains(0) { return .binary }
            guard let text = String(data: data, encoding: .utf8) else { return .binary }
            return .text(text)
        }.value
    }

    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
