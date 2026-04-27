import SwiftUI

/// Right column: top half lists changed files (`git status --porcelain=v2`),
/// bottom half renders the unified diff for the selected one. Re-fetches the
/// status while visible (3 s poll) and re-fetches the diff whenever the user
/// picks a different file. There's no UI for staging — the spec is explicit
/// about diff *view* only; use a terminal tab for any git command.
struct RightInspectorView: View {
    let project: Project?

    @State private var changes: [GitChange] = []
    @State private var selectedFile: URL?
    @State private var isStatusUnavailable: Bool = false
    @State private var diffText: String = ""
    @State private var isLoadingDiff: Bool = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let project {
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
            } else {
                emptyProjectState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: project?.id) {
            await startPolling()
        }
        .onChange(of: selectedFile) { _, newValue in
            Task { await refreshDiff(for: newValue) }
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
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 8) {
            Text("CHANGES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if !changes.isEmpty {
                Text("\(changes.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            Spacer()
            Button {
                Task { await refreshStatusOnce() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Refresh git status")
            .disabled(project == nil)
            .padding(.trailing, 6)
        }
        .padding(.leading, Inspector.hPadding)
        .padding(.trailing, Inspector.hPadding)
        .padding(.top, 18)
        .padding(.bottom, 12)
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
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No project selected")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status polling

    /// Drives a 3-second poll for `git status` while the inspector is on
    /// screen and a project is active. Cancelled on disappear / project
    /// switch via `.task(id:)` semantics.
    private func startPolling() async {
        // Reset per-project state on switch.
        changes = []
        selectedFile = nil
        diffText = ""
        isStatusUnavailable = false
        guard project != nil else { return }
        await refreshStatusOnce()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
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
                changes = result
            } else {
                isStatusUnavailable = true
                changes = []
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

/// Single source of truth for horizontal inset across the inspector — the
/// header, the list rows, and the diff content all line up to the same
/// gutter so nothing looks dragged left or right of anything else.
enum Inspector {
    static let hPadding: CGFloat = 14
}

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

    private var roots: [ChangeNode] { ChangeTree.build(from: changes) }

    /// Tree-walk that respects the current collapsed set. Returns rows in
    /// display order with their depth, ready for a flat List.
    private var visibleRows: [TreeRow] {
        var result: [TreeRow] = []
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
        return result
    }

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
                            .listRowInsets(EdgeInsets(top: 3,
                                                      leading: Inspector.hPadding,
                                                      bottom: 3,
                                                      trailing: Inspector.hPadding + 8))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowView(for row: TreeRow) -> some View {
        if let change = row.node.change {
            HStack(spacing: 0) {
                indentSpacer(depth: row.depth, isFile: true)
                ChangedFileRow(change: change)
            }
            .tag(change.url)
        } else {
            DirectoryRow(node: row.node,
                         depth: row.depth,
                         isExpanded: !collapsed.contains(row.node.id),
                         toggle: { toggle(row.node.id) })
        }
    }

    /// One indent level (14pt) per depth. The chevron column on directory
    /// rows is the same width, so a file at depth N visually sits below
    /// its parent's name without an extra column. List's own leading
    /// inset is collapsed via `listRowInsets` so this is the only indent.
    private func indentSpacer(depth: Int, isFile: Bool) -> some View {
        Color.clear.frame(width: CGFloat(depth) * 14)
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
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .light))
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
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(depth) * 14)
                // Pin chevron to the leading edge of its column so its
                // pivot point aligns with the leading edge of "CHANGES"
                // in the header above and with file rows below.
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10, alignment: .leading)
                Text(node.name)
                    .font(.system(size: 11, weight: .semibold))
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
        .padding(.vertical, 2)
    }
}

private struct ChangedFileRow: View {
    let change: GitChange

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(change.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(change.stateSubtitle)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(change.status.tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            stats
        }
        .padding(.vertical, 2)
        .help("\(change.stateSubtitle) — \(change.relativePath)")
    }

    @ViewBuilder
    private var stats: some View {
        if change.additions > 0 || change.deletions > 0 {
            HStack(spacing: 4) {
                if change.additions > 0 {
                    Text("+\(change.additions)")
                        .foregroundStyle(Color(red: 0.22, green: 0.78, blue: 0.45))
                }
                if change.deletions > 0 {
                    Text("−\(change.deletions)")
                        .foregroundStyle(Color(red: 0.90, green: 0.30, blue: 0.30))
                }
            }
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .monospacedDigit()
        }
    }

}

