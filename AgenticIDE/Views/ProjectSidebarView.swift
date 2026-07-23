import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProjectSidebarView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @EnvironmentObject private var updater: UpdaterManager
    @Binding var selectedProjectId: UUID?
    /// True while the window is NOT fullscreen: the panes now run to the very
    /// top of the window, so the sidebar header must start after the floating
    /// traffic lights. Fullscreen hides them, so the inset drops away.
    var reserveTrafficLights: Bool = true

    @State private var newGroupAlertShown = false
    @State private var newGroupName: String = ""
    @State private var renamingGroup: ProjectGroup?
    @State private var renameDraft: String = ""
    @State private var hoveredGroupId: UUID?
    /// Identifies which drop zone the cursor is currently over, so we can
    /// render a highlight there. Format: "group:<uuid>" or "ungrouped".
    @State private var hoveredDropKey: String?

    var body: some View {
        // Single O(N) bucket of the live project list keyed by groupId so
        // each section's lookup is O(1) instead of re-filtering the whole
        // array per group on every body invalidation. `nil` key holds the
        // ungrouped bucket. Per-render rebuild is cheap; the prior shape
        // was (G + 1) × N work for G groups + N projects.
        let projectsByGroup = bucketProjectsByGroup()
        let ungrouped = projectsByGroup[nil] ?? []

        let visibleCount = store.projects.filter { !$0.archived }.count

        return VStack(spacing: 0) {
            // The panes run to the window top, so windowed the floating
            // traffic lights get an empty strip to themselves and the
            // heading sits on its own row below (Codex-style). Fullscreen
            // hides the lights, so the strip collapses.
            if reserveTrafficLights {
                Color.clear.frame(height: DS.Control.header)
            }
            // Title left, project actions right-aligned on the same row.
            HStack(spacing: DS.Space.xs) {
                PaneTitle("Projects", count: visibleCount)
                SidebarHeaderAddButton(createProject: createProject,
                                       addProject: addProject)
                SidebarHeaderButton(systemName: "folder.badge.plus",
                                    help: "New Group",
                                    action: startNewGroup)
                SidebarHeaderButton(systemName: "arrow.triangle.2.circlepath",
                                    help: "Check for Updates",
                                    action: { updater.checkForUpdates() })
                    .disabled(!updater.canCheckForUpdates)
            }
            .padding(.leading, DS.Gutter.sidebar + DS.Space.sm)
            .padding(.trailing, DS.Space.sm)
            .frame(height: DS.Control.header)

            // `.scrollIndicators(.hidden)` alone doesn't reclaim the
            // trailing scroller gutter on macOS — the underlying NSScrollView
            // is left in `.legacy` style if the user's system setting is
            // "Always show scrollbars", so it inset its document view by
            // ~15pt on the right regardless. The `OverlayScrollerStyle`
            // view below introspects up to the enclosing NSScrollView and
            // forces `.overlay`, which is what eliminates the asymmetric
            // gap between the blue project tiles and the sidebar's right
            // border.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !ungrouped.isEmpty || !store.groups.isEmpty {
                        ungroupedSection(projects: ungrouped, hasGroups: !store.groups.isEmpty)
                    }

                    ForEach(store.sortedGroups) { group in
                        groupSection(group, projects: projectsByGroup[group.id] ?? [])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Gutter.sidebar)
                .padding(.top, DS.Space.md)
                .padding(.bottom, DS.Space.md)
                .background(OverlayScrollerStyle())
            }
            .scrollIndicators(.hidden)
            .background(.clear)
            .animation(.easeOut(duration: 0.12), value: hoveredDropKey)

            Divider()
            // Footer: weekly AI plan usage (Claude / Fable / Codex / Grok) + CPU · MEM.
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                UsageBar()
                ResourceBar()
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Sidebar surface (#1E1E1E dark) — a touch lifted off the main
        // Grok canvas (#141414) so the projects column reads as chrome.
        .background(DS.Surface.sidebar)
        // Menu-bar commands (File → New Project / Add Existing Project) post
        // these; the sidebar owns the panels + store so it observes here.
        .onReceive(NotificationCenter.default.publisher(for: .newProject)) { _ in
            createProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .addProject)) { _ in
            addProject()
        }
        .alert("New Group", isPresented: $newGroupAlertShown) {
            TextField("Name", text: $newGroupName)
            Button("Create") {
                let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    store.addGroup(name: trimmed)
                }
                newGroupName = ""
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        } message: {
            Text("Name this group (e.g. Work, Personal).")
        }
        .alert("Rename Group", isPresented: Binding(
            get: { renamingGroup != nil },
            set: { if !$0 { renamingGroup = nil } }
        )) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if let g = renamingGroup, !trimmed.isEmpty {
                    store.renameGroup(id: g.id, to: trimmed)
                }
                renamingGroup = nil
            }
            Button("Cancel", role: .cancel) { renamingGroup = nil }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func groupHeader(_ group: ProjectGroup, isEmpty: Bool) -> some View {
        let isHovered = hoveredGroupId == group.id

        HStack(spacing: DS.Space.xxs) {
            Image(systemName: "chevron.right")
                .font(.system(size: DS.Icon.micro, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                .frame(width: DS.Tree.chevronColumn)
                .animation(.easeInOut(duration: 0.15), value: group.collapsed)

            Text(group.name)
                .font(DS.Font.sectionCaps)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DS.Space.xs)

            // Always present in the layout (opacity gated) so hover doesn't reflow the row.
            SidebarIconButton(systemName: "square.and.pencil",
                              help: "Rename group",
                              enabled: true) {
                renameDraft = group.name
                renamingGroup = group
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)

            SidebarIconButton(systemName: "trash",
                              help: isEmpty ? "Delete group" : "Move or remove projects first",
                              enabled: isEmpty) {
                store.removeGroup(id: group.id)
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .transaction { $0.animation = nil }
        }
        // Trailing padding matches `projectRowItem`'s horizontal inset
        // (DS.Space.sm) so the pencil/trash buttons sit on the same vertical
        // line as the right edge of the project tiles below.
        .frame(minHeight: DS.Control.standard)
        .padding(.leading, DS.Space.sm)
        .padding(.trailing, DS.Space.sm)
        .padding(.top, DS.Space.xs)
        .padding(.bottom, isEmpty ? DS.Space.xs : DS.Space.xs)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                store.toggleGroupCollapsed(id: group.id)
            }
        }
        .onHover { inside in
            if inside {
                hoveredGroupId = group.id
            } else if hoveredGroupId == group.id {
                hoveredGroupId = nil
            }
        }
        .contextMenu {
            Button(group.collapsed ? "Expand" : "Collapse") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    store.toggleGroupCollapsed(id: group.id)
                }
            }
            Button("Rename…") {
                renameDraft = group.name
                renamingGroup = group
            }
            Divider()
            Button("Delete Group", role: .destructive) {
                store.removeGroup(id: group.id)
            }
            .disabled(!isEmpty)
        }
    }

    @ViewBuilder
    private func ungroupedSection(projects: [Project], hasGroups: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            // Same section-cap visual treatment as `groupHeader` so all the
            // section labels read as one tier ("UNGROUPED", "WORK",
            // "FLIPPEDIT", "SIDE PROJECTS"). Earlier this header used the
            // old subheadline-semibold-primary style and looked like a
            // project name competing with the rows.
            Text(hasGroups ? "Ungrouped" : "Projects")
                .font(DS.Font.sectionCaps)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, DS.Space.sm)
                .padding(.trailing, DS.Space.sm)
                .padding(.top, DS.Space.xs)
                .padding(.bottom, projects.isEmpty ? DS.Space.xs : DS.Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(DropZoneHighlight(active: hoveredDropKey == "ungrouped"))

            ForEach(projects) { project in
                projectRowItem(project)
            }
        }
        .padding(.bottom, DS.Space.md)
        // Section-level drop (header / empty padding): append to end of Ungrouped.
        // Project rows own their own drop targets for insert-before placement.
        .dropDestination(for: String.self) { items, _ in
            moveProjects(from: items, to: nil, before: nil)
        } isTargeted: { entering in
            isTargetedBinding("ungrouped").wrappedValue = entering
        }
    }

    @ViewBuilder
    private func groupSection(_ group: ProjectGroup, projects groupProjects: [Project]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            groupHeader(group, isEmpty: groupProjects.isEmpty)
                .modifier(DropZoneHighlight(active: hoveredDropKey == "group:\(group.id.uuidString)"))
                .draggable("group:\(group.id.uuidString)") {
                    Label(group.name, systemImage: "folder.fill.badge.gearshape")
                        .padding(DS.Space.sm)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
                }

            if !group.collapsed {
                ForEach(groupProjects) { project in
                    projectRowItem(project)
                }
            }
        }
        .padding(.bottom, DS.Space.md)
        // Section-level drop: group payloads reorder groups; project payloads
        // append at the end of this group. Row-level drops handle insert-before.
        .dropDestination(for: String.self) { items, _ in
            handleSectionDrop(items, targetGroupId: group.id)
        } isTargeted: { entering in
            let key = "group:\(group.id.uuidString)"
            isTargetedBinding(key).wrappedValue = entering
        }
    }

    @ViewBuilder
    private func projectRowItem(_ project: Project) -> some View {
        let isSelected = selectedProjectId == project.id
        let liveSession = isSelected ? sessions.session(for: project.id) : sessions.liveSession(for: project.id)

        Group {
            if let session = liveSession {
                ProjectRow(project: project,
                           session: session,
                           isExpanded: isSelected,
                           onSelectWorkspace: { id in
                               selectedProjectId = project.id
                               session.activeWorkspaceId = id
                           },
                           onAddWorkspace: {
                               // The "+ row" only shows on the selected (expanded)
                               // project, so its pane ④ is mounted and will catch
                               // this and show the layout chooser.
                               selectedProjectId = project.id
                               NotificationCenter.default.post(name: .newWorkspace, object: nil)
                           },
                           onCloseWorkspace: { id in session.removeWorkspace(id: id) },
                           onRenameWorkspace: { id, name in session.renameWorkspace(id: id, to: name) })
            } else {
                ProjectSummaryRow(project: project,
                                  savedWorkspaceCount: sessions.savedWorkspaceCount(for: project.id))
            }
        }
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.xs)
            // Force the padded view to claim the parent's full width before
            // the background draws, so the blue tile spans edge-to-edge of
            // the sidebar's content area (gutter on both sides matches).
            // Without this, the tile sized to its natural content width and
            // left a wider empty strip on the right than the left.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                // No withAnimation here: the transaction would propagate into
                // pane ④'s workspace slide transition, making project swaps
                // slide like a workspace swipe.
                selectedProjectId = project.id
            }
            .draggable(project.id.uuidString) {
                Label(project.name, systemImage: "folder.fill")
                    .padding(DS.Space.sm)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
            }
            // Drop onto a row → insert immediately above it (same group as the
            // target row). Gives ordered placement inside a category instead of
            // always landing at the section top/end.
            .dropDestination(for: String.self) { items, _ in
                moveProjects(from: items, to: project.groupId, before: project.id)
            } isTargeted: { entering in
                isTargetedBinding("before:\(project.id.uuidString)").wrappedValue = entering
            }
            .modifier(DropInsertHighlight(active: hoveredDropKey == "before:\(project.id.uuidString)"))
            .contextMenu {
                if let ide = ExternalIDEService.preferredIDE() {
                    Button("Open in \(ide.displayName)") {
                        ExternalIDEService.open(project.path, in: ide)
                    }
                }
                let installed = ExternalIDEService.installedIDEs()
                if installed.count > 1 {
                    Menu("Open in...") {
                        ForEach(installed) { ide in
                            Button(ide.displayName) {
                                ExternalIDEService.open(project.path, in: ide)
                            }
                        }
                    }
                }
                Divider()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([project.path])
                }
                Menu("Move to") {
                    if project.groupId != nil {
                        Button("Ungrouped") {
                            store.setProjectGroup(projectId: project.id, groupId: nil)
                        }
                    }
                    ForEach(store.sortedGroups) { g in
                        if g.id != project.groupId {
                            Button(g.name) {
                                store.setProjectGroup(projectId: project.id, groupId: g.id)
                            }
                        }
                    }
                    Divider()
                    Button("New Group…") { startNewGroup() }
                }
                Button("Archive") {
                    store.setArchived(id: project.id, archived: true)
                }
                Divider()
                Button("Remove", role: .destructive) {
                    store.remove(id: project.id)
                }
            }
    }

    // MARK: - Actions

    /// One pass over `store.projects` that buckets into `[groupId: [Project]]`.
    /// Filters out archived rows up front so callers don't re-check. Group
    /// keys preserve the relative ordering from `store.projects`; the
    /// section views render this directly without a second sort.
    private func bucketProjectsByGroup() -> [UUID?: [Project]] {
        var buckets: [UUID?: [Project]] = [:]
        for project in store.projects where !project.archived {
            buckets[project.groupId, default: []].append(project)
        }
        return buckets
    }

    /// Moves every project UUID in `items` into `groupId`, inserting each
    /// immediately before `before` (nil = append after the group's last member).
    /// Group payloads (`group:…`) are ignored — those only reorder via section drop.
    @discardableResult
    private func moveProjects(from items: [String], to groupId: UUID?, before: UUID?) -> Bool {
        var didSomething = false
        for raw in items {
            if raw.hasPrefix("group:") { continue }
            guard let id = UUID(uuidString: raw) else { continue }
            store.moveProject(id: id, toGroup: groupId, before: before)
            didSomething = true
        }
        return didSomething
    }

    /// Dispatches a drop on a group's section. Group payloads reorder; project
    /// payloads append into the group (row drops handle insert-before).
    private func handleSectionDrop(_ items: [String], targetGroupId: UUID) -> Bool {
        var didSomething = false
        for raw in items {
            if raw.hasPrefix("group:") {
                let uuidString = String(raw.dropFirst("group:".count))
                guard let movingId = UUID(uuidString: uuidString),
                      movingId != targetGroupId else { continue }
                store.reorderGroup(id: movingId, before: targetGroupId)
                didSomething = true
            } else if let pid = UUID(uuidString: raw) {
                store.moveProject(id: pid, toGroup: targetGroupId, before: nil)
                didSomething = true
            }
        }
        return didSomething
    }

    /// Returns a Binding<Bool> for `dropDestination(isTargeted:)` keyed by a
    /// stable string id; setting it true marks that drop zone as the cursor's
    /// current target, false clears only if it was previously this zone.
    private func isTargetedBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { hoveredDropKey == key },
            set: { entering in
                if entering {
                    hoveredDropKey = key
                } else if hoveredDropKey == key {
                    hoveredDropKey = nil
                }
            }
        )
    }

    private func startNewGroup() {
        newGroupName = ""
        newGroupAlertShown = true
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let project = store.add(folder: url)
        selectedProjectId = project.id
    }

    /// Creates a brand-new project folder on disk, then adds it (ungrouped).
    /// A single NSSavePanel lets the user pick a location and type the folder
    /// name in one dialog; the typed name becomes both the directory name and
    /// the project name. We never adopt or clobber an existing path — if one
    /// is already there we warn and bail so "New" can't silently overwrite.
    private func createProject() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.prompt = "Create"
        panel.title = "New Project"
        panel.message = "Choose a location and name for the new project folder."
        panel.nameFieldLabel = "Project Name:"
        panel.nameFieldStringValue = "New Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            presentCreateError(
                title: "“\(url.lastPathComponent)” already exists",
                message: "A file or folder with that name is already at this location. Pick a different name or location.")
            return
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            presentCreateError(title: "Couldn’t create project folder",
                               message: error.localizedDescription)
            return
        }
        let project = store.add(folder: url)
        selectedProjectId = project.id
    }

    private func presentCreateError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Renders an accent-tinted background + insertion bar on the leading edge
/// when a drag is hovering over the wrapped section header. Communicates
/// "release here" without obstructing the underlying content.
private struct DropZoneHighlight: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .padding(.leading, active ? 6 : 0)
            .background(alignment: .leading) {
                HStack(spacing: 0) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.vertical, 2)
                        .opacity(active ? 1 : 0)
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(Color.accentColor.opacity(active ? 0.16 : 0.0))
                }
            }
    }
}

/// Horizontal insertion line above a project row while a drag targets that
/// row as "insert before me".
private struct DropInsertHighlight: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, DS.Space.sm)
                    .offset(y: -1)
                    .opacity(active ? 1 : 0)
            }
    }
}

/// Compact icon button in the Projects header row — just the glyph with a
/// small hit area and a hover background, no big pill.
private struct SidebarHeaderButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.10 : 0.0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// The "+" header button — same compact look, but opens the New / Add Existing
/// project popover instead of firing a single action. Anchored under the title
/// so the menu drops into the project list (arrowEdge: .bottom).
private struct SidebarHeaderAddButton: View {
    let createProject: () -> Void
    let addProject: () -> Void

    @State private var isHovered = false
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.10 : 0.0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Button("New Project…") {
                    isPresented = false
                    createProject()
                }
                Button("Add Existing Project…") {
                    isPresented = false
                    addProject()
                }
            }
            .buttonStyle(.plain)
            .padding(DS.Space.md)
            .frame(width: 180, alignment: .leading)
            .presentationCornerRadius(DS.Radius.popover)
        }
        .help("New or existing project")
    }
}

/// Trailing-anchored hover icon used on group headers. The glyph sits at the
/// **right edge of its frame** (alignment: .trailing) so its visible right
/// edge lines up with the right edge of the project tiles below — without
/// that anchor the glyph naturally centres in a 22pt button and ends up
/// floating ~4pt to the left of the tiles' blue border.
///
/// Visibility is gated by the parent row's hover state (opacity 0/1), so the
/// button doesn't need its own hover background — that was making the
/// alignment harder to reason about for no UX gain.
private struct SidebarIconButton: View {
    let systemName: String
    let help: String
    let enabled: Bool
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(DS.Font.bodySemibold)
                .foregroundStyle(enabled ? Color.secondary : Color.primary.opacity(0.35))
                .frame(width: DS.Control.compact,
                       height: DS.Control.compact,
                       alignment: .trailing)
                .contentShape(Rectangle())
                .scaleEffect(isPressed ? 0.94 : 1.0)
                .animation(.easeOut(duration: 0.08), value: isPressed)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if enabled { isPressed = true } }
                .onEnded { _ in isPressed = false }
        )
        .help(help)
    }
}

private struct ProjectSummaryRow: View {
    let project: Project
    let savedWorkspaceCount: Int

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
            Text(project.name)
                .font(.body.weight(.medium))
                .lineLimit(1)
            if savedWorkspaceCount > 0 {
                WorkspaceCountBadge(count: savedWorkspaceCount)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, DS.Space.xxs)
    }
}

private struct ProjectRow: View {
    let project: Project
    @Bindable var session: ProjectSession
    let isExpanded: Bool
    let onSelectWorkspace: (UUID) -> Void
    let onAddWorkspace: () -> Void
    let onCloseWorkspace: (UUID) -> Void
    let onRenameWorkspace: (UUID, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                Text(project.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if !session.workspaces.isEmpty {
                    WorkspaceCountBadge(count: session.workspaces.count)
                }
                Spacer(minLength: 4)
                // Live mini-grids — collapsed rows only. One glyph per workspace
                // (capped) shows each grid's shape + per-cell status at a glance.
                // When expanded, each workspace row shows its own glyph.
                if !isExpanded, !session.workspaces.isEmpty {
                    HStack(spacing: DS.Space.sm) {
                        ForEach(session.workspaces.prefix(3)) { ws in
                            WorkspaceGridGlyph(workspace: ws, square: 7, gap: 1.5, corner: 2)
                        }
                    }
                }
            }

            // Workspace children — only when selected. Revealed by the card
            // growing (no slide-from-top — that read as "adding" rows).
            if isExpanded {
                VStack(spacing: 1) {
                    ForEach(session.workspaces) { ws in
                        WorkspaceChildRow(workspace: ws,
                                          isActive: session.activeWorkspaceId == ws.id,
                                          onSelect: { onSelectWorkspace(ws.id) },
                                          onClose: { onCloseWorkspace(ws.id) },
                                          onRename: { newName in onRenameWorkspace(ws.id, newName) })
                    }
                    AddWorkspaceRow(action: onAddWorkspace)
                }
                // Indent under the folder + title so children read nested.
                .padding(.leading, DS.Space.lg + 2)
                .padding(.trailing, DS.Space.xs)
                .transition(.identity)
            }
        }
        .padding(.vertical, DS.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Height-only feel: short ease, no spring bounce on expand/collapse.
        .animation(.easeInOut(duration: 0.14), value: isExpanded)
        .animation(.easeInOut(duration: 0.14), value: session.workspaces.map(\.id))
    }
}

/// Compact count pill next to a project title (workspace count).
private struct WorkspaceCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
            .help(count == 1 ? "1 workspace" : "\(count) workspaces")
    }
}

/// Live elapsed-time readout for a working agent. `TimelineView` re-renders
/// just this label once a second, so the rest of the sidebar doesn't pay for
/// the tick — and there's no shared runloop timer to manage.
/// Always a single horizontal line (`⏱ 0:03`) — never wraps in a tight row.
private struct WorkingTimerLabel: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 3) {
                Image(systemName: "timer")
                    .font(.system(size: 10, weight: .semibold))
                Text(Self.format(context.date.timeIntervalSince(since)))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(TerminalStatusBadge.info(for: .working)?.color ?? .secondary)
            .fixedSize(horizontal: true, vertical: true)
            .layoutPriority(1)
        }
    }

    /// m:ss under an hour, h:mm:ss after.
    static func format(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        if total < 3600 {
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// One workspace row nested under a project. Click selects + activates it,
/// hover reveals close, double-click swaps the name into an inline TextField.
/// Working-agent timer sits after the name so you see which workspace is busy.
private struct WorkspaceChildRow: View {
    @Bindable var workspace: Workspace
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var draftName: String = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        // Tight spacing: glyph uses its natural width (was a 24pt slot that
        // left a wide gap before the name for small grids).
        HStack(spacing: DS.Space.xs) {
            // Live mini-grid — encodes the layout AND each cell's status
            // (blue = working, green = done), replacing the old icon + dots.
            WorkspaceGridGlyph(workspace: workspace, square: 4.5, gap: 1.2)
                .fixedSize()

            if isEditing {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: DS.FontSize.body, weight: isActive ? .semibold : .regular))
                    .focused($nameFieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isEditing = false }
            } else {
                Text(workspace.name)
                    .font(.system(size: DS.FontSize.body, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Name yields width to the timer so "0:03" never stacks.
                    .layoutPriority(0)
            }

            if let since = workingSince {
                WorkingTimerLabel(since: since)
            }

            Spacer(minLength: DS.Space.xs)
            // Reserve close-button space so layout doesn't reflow on hover.
            Color.clear.frame(width: DS.Control.compact, height: DS.Control.badge)
        }
        .lineLimit(1)
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.xs)
        .frame(minHeight: DS.Control.standard)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(isActive
                      ? Color.accentColor.opacity(0.22)
                      : (isHovered ? Color.primary.opacity(0.06) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRename() }
        .onTapGesture { onSelect() }
        .overlay(alignment: .trailing) {
            // Close button rides above the tappable row. `allowsHitTesting`
            // gates clicks to hovered+non-editing so it can't be hit by
            // accident; opacity is tied to the same state for the visual.
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: DS.Icon.micro, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: DS.Control.badge, height: DS.Control.badge)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .fill(Color.primary.opacity(0.10))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, DS.Space.sm + 1)
            .opacity(isHovered && !isEditing ? 1 : 0)
            .allowsHitTesting(isHovered && !isEditing)
            .help("Close workspace")
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Rename…") { startRename() }
            Divider()
            Button("Close Workspace", role: .destructive) { onClose() }
        }
    }

    /// Earliest `.working` start among cells in this workspace, if any.
    private var workingSince: Date? {
        workspace.runningCells
            .compactMap { $0.terminal?.status == .working ? $0.terminal?.workingSince : nil }
            .min()
    }

    private func startRename() {
        draftName = workspace.name
        isEditing = true
        DispatchQueue.main.async { nameFieldFocused = true }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { onRename(trimmed) }
        isEditing = false
    }
}

/// "New Workspace" affordance shown at the bottom of an expanded project.
private struct AddWorkspaceRow: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "plus")
                    .font(DS.Font.control)
                    .foregroundStyle(.secondary)
                    .frame(width: DS.Tree.iconColumn - 2)
                Text("New Workspace")
                    .font(.system(size: DS.FontSize.body))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.xs)
            .frame(minHeight: DS.Control.standard)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Add a workspace to this project")
    }
}

/// Small `● Label` indicator used on collapsed project rows so the user can
/// see "Working" / "Question" / "Completed" / "Failed" without expanding the
/// row. The per-tab rows render the dot+label inline in their own layout
/// instead of using this view, so they can match the row's typography.
struct TerminalStatusBadge: View {
    let status: TerminalTabStatus

    var body: some View {
        if let info = Self.info(for: status) {
            HStack(spacing: DS.Space.xs) {
                Circle()
                    .fill(info.color)
                    .frame(width: DS.Space.sm, height: DS.Space.sm)
                Text(info.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(info.color)
            }
        }
    }

    struct Info {
        let label: String
        let color: Color
    }

    /// Single source of truth for the colour + label of each status. Returns
    /// nil for `.idle` so callers know to fall back to their default chrome.
    static func info(for status: TerminalTabStatus) -> Info? {
        switch status {
        case .idle:
            return nil
        case .working:
            // Soft blue: in-progress, neutral. Pulses in the per-tab row to
            // reinforce "still moving."
            return Info(label: "Working", color: Color(red: 0.30, green: 0.62, blue: 0.95))
        case .completed:
            return Info(label: "Completed", color: Color(red: 0.30, green: 0.78, blue: 0.45))
        case .failed:
            return Info(label: "Failed", color: Color(red: 0.92, green: 0.36, blue: 0.36))
        }
    }
}

/// Walks up the AppKit hierarchy to the enclosing `NSScrollView` and forces
/// its scroller style to `.overlay`. SwiftUI's `.scrollIndicators(.hidden)`
/// only hides the bar; it doesn't switch the underlying `NSScrollView` out
/// of `.legacy` mode if the user's system setting is "Always show scroll
/// bars". In `.legacy` mode the document view is inset on the trailing
/// side by the scroller width (~15pt), which is exactly the asymmetric gap
/// we were seeing on the right side of the project tiles.
private struct OverlayScrollerStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // Defer to the next run loop so the view is in the hierarchy and
        // `enclosingScrollView` actually returns something.
        DispatchQueue.main.async { Self.apply(to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: nsView) }
    }

    private static func apply(to view: NSView) {
        guard let scrollView = view.enclosingScrollView else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.scrollerStyle = .overlay
        scrollView.horizontalScroller?.scrollerStyle = .overlay
    }
}
