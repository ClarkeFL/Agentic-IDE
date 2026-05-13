import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pane 2 of the four-pane layout. Shows the project file tree with
/// expand-on-click directory rows and click-to-open file rows that route
/// the URL into `EditorSession.open`. Right-click → New File / New Folder /
/// Rename / Reveal / Delete. Drag a row onto a folder row to move it.
///
/// The tree itself is a flat list of `FileTreeRow` rebuilt whenever
/// `rootNodes`, `expanded`, or `childrenCache` change — same pattern as the
/// retired right-inspector files mode, kept here for animation parity.
struct FileTreeView: View {
    let project: Project
    @Bindable var editor: EditorSession
    @Bindable var gitWatcher: GitStatusWatcher

    @State private var rootNodes: [FileNode] = []
    @State private var childrenCache: [String: [FileNode]] = [:]
    @State private var expanded: Set<String> = []
    @State private var loading: Set<String> = []
    @State private var isLoadingRoot: Bool = false
    @State private var visibleRows: [FileTreeRow] = []
    @State private var selection: URL?
    @State private var hoverDropKey: String?
    /// Bumped to force a manual re-walk of the root (used by the header's
    /// refresh button).
    @State private var refreshToken: Int = 0
    /// Pane-2 view mode. `.files` shows the project's file tree; `.changes`
    /// shows only files git knows have working-tree edits since HEAD.
    @State private var paneMode: PaneMode = .files

    enum PaneMode: Hashable { case files, changes }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch paneMode {
                case .files:
                    if isLoadingRoot && rootNodes.isEmpty {
                        centered("Loading…", systemImage: "folder")
                    } else if rootNodes.isEmpty {
                        centered("Folder is empty", systemImage: "folder")
                    } else {
                        treeList
                    }
                case .changes:
                    ChangesListView(project: project,
                                    editor: editor,
                                    gitWatcher: gitWatcher)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .contextMenu {
                if paneMode == .files {
                    emptyContextMenu(parent: project.path)
                }
            }
            GitFooterBar(project: project, gitWatcher: gitWatcher)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: TaskKey(path: project.path, token: refreshToken)) {
            await loadRoot()
        }
        // Git status polling. The watcher itself runs the loop; we just
        // bind its lifetime to this pane so a project switch / pane
        // disappearance cancels the loop.
        .task(id: project.id) {
            await gitWatcher.runPollLoop()
        }
        .onChange(of: rootNodes) { _, _ in rebuildVisibleRows() }
        .onChange(of: expanded) { _, _ in rebuildVisibleRows() }
        .onChange(of: childrenCache) { _, _ in rebuildVisibleRows() }
        // Keep the tree's selection in lock-step with whatever the editor
        // pane has activated (e.g., user closed a tab and we should
        // de-emphasise that file's row).
        .onChange(of: editor.activeTabId) { _, _ in
            selection = editor.activeTab?.url
        }
        // Tree-driven open. Clicking a leaf sets `selection`; we route into
        // the editor here. SwiftUI's onChange dedupes equal values, so the
        // mirror-update from the activeTabId onChange above doesn't loop.
        .onChange(of: selection) { _, new in
            guard let url = new else { return }
            editor.open(url)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.Space.xs) {
            paneModeToggle
            Spacer(minLength: 0)
            if paneMode == .files {
                HeaderIconButton(systemName: "doc.badge.plus",
                                 help: "New file in project root") {
                    promptNewItem(in: project.path, kind: .file)
                }
                HeaderIconButton(systemName: "folder.badge.plus",
                                 help: "New folder in project root") {
                    promptNewItem(in: project.path, kind: .folder)
                }
            }
            HeaderIconButton(systemName: "arrow.clockwise",
                             help: "Refresh") {
                refreshToken &+= 1
                childrenCache = [:]
                Task { await gitWatcher.refresh() }
            }
        }
        .padding(.leading, DS.Gutter.inspector)
        .padding(.trailing, DS.Space.sm)
        .frame(height: DS.Control.header)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    /// Two-segment pill that swaps the pane between the project file tree
    /// and the working-tree changes list. Icon-only chips with a hover
    /// popover spelling out the verb so the toggle stays compact.
    private var paneModeToggle: some View {
        HStack(spacing: 2) {
            paneModeChip(systemName: "folder",
                         mode: .files,
                         title: "Files",
                         subtitle: "Browse the project's file tree.",
                         badge: nil)
            paneModeChip(systemName: "pencil.line",
                         mode: .changes,
                         title: "Changes",
                         subtitle: gitWatcher.isGitRepo
                             ? (gitWatcher.changes.isEmpty
                                 ? "Working tree is clean."
                                 : "Show \(gitWatcher.changes.count) file\(gitWatcher.changes.count == 1 ? "" : "s") with uncommitted edits.")
                             : "Not a git repository.",
                         badge: gitWatcher.isGitRepo && !gitWatcher.changes.isEmpty
                             ? gitWatcher.changes.count
                             : nil)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    @ViewBuilder
    private func paneModeChip(systemName: String,
                              mode: PaneMode,
                              title: String,
                              subtitle: String,
                              badge: Int?) -> some View {
        let isOn = paneMode == mode
        Button {
            paneMode = mode
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(width: 28, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .fill(isOn ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                    )
                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 12, minHeight: 11)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 4, y: -3)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverInfo(title: title, subtitle: subtitle)
    }

    // MARK: - Tree list

    private var treeList: some View {
        List(selection: $selection) {
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

    @ViewBuilder
    private func rowView(for row: FileTreeRow) -> some View {
        if row.node.isDirectory {
            FileDirectoryRow(
                node: row.node,
                depth: row.depth,
                isExpanded: expanded.contains(row.node.id),
                isLoading: loading.contains(row.node.id),
                isHoverDropTarget: hoverDropKey == row.node.id,
                rollupStatus: gitWatcher.folderStatus(for: row.node.url),
                toggle: { toggle(row.node) }
            )
            .contextMenu { directoryContextMenu(for: row.node) }
            .onDrag { NSItemProvider(object: row.node.url as NSURL) }
            .onDrop(of: [.fileURL], isTargeted: Binding(
                get: { hoverDropKey == row.node.id },
                set: { hoverDropKey = $0 ? row.node.id : (hoverDropKey == row.node.id ? nil : hoverDropKey) }
            )) { providers in
                handleDrop(providers: providers, into: row.node.url)
            }
        } else {
            FileLeafRow(node: row.node,
                        depth: row.depth,
                        status: gitWatcher.status(for: row.node.url)) {
                editor.open(row.node.url)
            }
                .tag(row.node.url)
                .contextMenu { fileContextMenu(for: row.node) }
                .onDrag { NSItemProvider(object: row.node.url as NSURL) }
        }
    }

    /// Composite id so `.task(id:)` re-fires when either the project path
    /// changes (project switch) OR the manual refresh token bumps.
    private struct TaskKey: Hashable {
        let path: URL
        let token: Int
    }

    // MARK: - State updates

    private func loadRoot() async {
        await MainActor.run {
            isLoadingRoot = true
        }
        let nodes = await FileBrowser.list(project.path)
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

    // MARK: - Context menus

    @ViewBuilder
    private func directoryContextMenu(for node: FileNode) -> some View {
        Button("New File…") { promptNewItem(in: node.url, kind: .file) }
        Button("New Folder…") { promptNewItem(in: node.url, kind: .folder) }
        Divider()
        Button("Rename…") { promptRename(node) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
        Divider()
        Button("Delete", role: .destructive) { confirmDelete(node) }
    }

    @ViewBuilder
    private func fileContextMenu(for node: FileNode) -> some View {
        Button("Open") { editor.open(node.url) }
        if Self.isHTML(node.url) {
            Button("Open in Browser") {
                NSWorkspace.shared.open(node.url)
            }
        }
        Divider()
        Button("Rename…") { promptRename(node) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
        Divider()
        Button("Delete", role: .destructive) { confirmDelete(node) }
    }

    private static func isHTML(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }

    /// Shown on right-click in the empty area of the tree (below all rows
    /// or in the placeholder when the project is empty).
    @ViewBuilder
    private func emptyContextMenu(parent: URL) -> some View {
        Button("New File in Project Root…") { promptNewItem(in: parent, kind: .file) }
        Button("New Folder in Project Root…") { promptNewItem(in: parent, kind: .folder) }
    }

    // MARK: - File operations

    private enum NewItemKind { case file, folder }

    /// NSAlert-based input for new file / new folder. SwiftUI doesn't give
    /// us a single-prompt-with-textfield primitive; AppKit's `accessoryView`
    /// is the clean way to do it without a full sheet.
    private func promptNewItem(in parent: URL, kind: NewItemKind) {
        let alert = NSAlert()
        alert.messageText = kind == .file ? "New File" : "New Folder"
        alert.informativeText = "In \(parent.lastPathComponent)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = kind == .file ? "filename.ext" : "folder name"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !raw.contains("/") else { return }

        let target = parent.appendingPathComponent(raw)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            failure(title: "Already exists",
                    detail: "An item named “\(raw)” already exists in \(parent.lastPathComponent).")
            return
        }
        do {
            switch kind {
            case .file:
                fm.createFile(atPath: target.path, contents: Data())
            case .folder:
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
            }
        } catch {
            failure(title: "Couldn't create item", detail: error.localizedDescription)
            return
        }
        invalidate(parent: parent)
        if kind == .file {
            editor.open(target)
        }
    }

    private func promptRename(_ node: FileNode) {
        let alert = NSAlert()
        alert.messageText = "Rename \(node.name)"
        alert.informativeText = "Enter a new name."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = node.name
        input.selectText(nil)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !raw.contains("/"), raw != node.name else { return }

        let dest = node.url.deletingLastPathComponent().appendingPathComponent(raw)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            failure(title: "Already exists",
                    detail: "An item named “\(raw)” already exists.")
            return
        }
        do {
            try fm.moveItem(at: node.url, to: dest)
        } catch {
            failure(title: "Couldn't rename", detail: error.localizedDescription)
            return
        }
        editor.handleRename(from: node.url, to: dest)
        invalidate(parent: node.url.deletingLastPathComponent())
    }

    private func confirmDelete(_ node: FileNode) {
        let alert = NSAlert()
        alert.messageText = "Move \(node.name) to the Trash?"
        alert.informativeText = node.isDirectory
            ? "This folder and everything inside it will be moved to the Trash."
            : "This file will be moved to the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
        } catch {
            failure(title: "Couldn't delete", detail: error.localizedDescription)
            return
        }
        editor.handleDeleted(node.url)
        invalidate(parent: node.url.deletingLastPathComponent())
    }

    // MARK: - Drag-and-drop move

    private func handleDrop(providers: [NSItemProvider], into folder: URL) -> Bool {
        var handled = false
        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else { continue }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let source = url else { return }
                Task { @MainActor in
                    self.performMove(source: source, into: folder)
                }
            }
            handled = true
        }
        return handled
    }

    @MainActor
    private func performMove(source: URL, into folder: URL) {
        // Same parent → noop.
        if source.deletingLastPathComponent() == folder { return }
        // Don't drop a folder into itself or into one of its descendants.
        if folder.path == source.path { return }
        if folder.path.hasPrefix(source.path + "/") { return }

        let dest = folder.appendingPathComponent(source.lastPathComponent)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            failure(title: "Already exists",
                    detail: "An item named “\(source.lastPathComponent)” already exists in \(folder.lastPathComponent).")
            return
        }
        do {
            try fm.moveItem(at: source, to: dest)
        } catch {
            failure(title: "Couldn't move item", detail: error.localizedDescription)
            return
        }
        editor.handleRename(from: source, to: dest)
        invalidate(parent: source.deletingLastPathComponent())
        invalidate(parent: folder)
    }

    // MARK: - Cache invalidation

    /// Invalidate the cached children of `parent` and reload them. If the
    /// parent is the project root, refreshes `rootNodes` instead.
    private func invalidate(parent: URL) {
        if parent == project.path {
            Task {
                let nodes = await FileBrowser.list(project.path)
                await MainActor.run { rootNodes = nodes }
            }
        } else {
            // Only refresh if we already had it in cache (i.e. the user has
            // ever expanded it). Otherwise the next expand will read fresh.
            if childrenCache[parent.path] != nil {
                Task {
                    let kids = await FileBrowser.list(parent)
                    await MainActor.run { childrenCache[parent.path] = kids }
                }
            }
        }
    }

    // MARK: - Helpers

    private func failure(title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

// MARK: - Rows

private struct FileTreeRow: Identifiable, Hashable {
    let node: FileNode
    let depth: Int
    var id: String { node.id }
}

private struct FileDirectoryRow: View {
    let node: FileNode
    let depth: Int
    let isExpanded: Bool
    let isLoading: Bool
    let isHoverDropTarget: Bool
    /// Most-severe git status of any descendant. Used to draw a small
    /// coloured dot on the right edge so collapsed folders surface
    /// "something inside has changed" without expanding.
    let rollupStatus: GitFileStatus?
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
                    .foregroundStyle(rollupStatus == nil ? .primary : Color(rollupStatus!.tint))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let status = rollupStatus {
                    Circle()
                        .fill(status.tint)
                        .frame(width: 6, height: 6)
                        .padding(.trailing, 2)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, DS.Space.xxs)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(isHoverDropTarget ? Color.accentColor.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct FileLeafRow: View {
    let node: FileNode
    let depth: Int
    /// Working-tree status if git knows this file. nil = clean / not tracked
    /// at all (e.g. inside `.gitignore`). VS Code colours the filename and
    /// adds a single-letter badge to the right edge — we mirror that.
    let status: GitFileStatus?
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(depth) * DS.Tree.indentStep + DS.Tree.chevronColumn)
            Image(systemName: "doc")
                .font(DS.Font.footnote)
                .foregroundStyle(status == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(status!.tint))
                .frame(width: DS.Tree.iconColumn, alignment: .leading)
            Text(node.name)
                .font(DS.Font.body)
                .foregroundStyle(status == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(status!.tint))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DS.Space.xs)
            if let status {
                Text(status.indicator)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(status.tint)
                    .padding(.trailing, 2)
            }
        }
        .padding(.vertical, DS.Space.xs)
        .contentShape(Rectangle())
        // Always-fires open gesture. We can't rely on `List`'s selection
        // change because clicking a row that's already selected dedupes
        // and never fires our `.onChange(of: selection)`. The simultaneous
        // gesture rides alongside the List's row-selection click so both
        // behaviours work — selection updates AND open fires every click.
        .simultaneousGesture(TapGesture().onEnded { onOpen() })
        .help(status.map { "\(node.url.path)\n\($0.label)" } ?? node.url.path)
    }
}

// MARK: - Header buttons

private struct HeaderIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(Color.primary.opacity(isPressed ? 0.14 : (isHovered ? 0.08 : 0.0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
