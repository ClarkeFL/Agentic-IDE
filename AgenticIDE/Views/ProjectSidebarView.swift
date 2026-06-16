import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProjectSidebarView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @EnvironmentObject private var updater: UpdaterManager
    @Binding var selectedProjectId: UUID?

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
            // Top strip — locked to the same height as the tab bar and the
            // inspector header so the three columns share one baseline.
            // Align the title to the sidebar content gutter; the title sits
            // below the traffic-light row, so reserving that inset made the
            // header read as centered instead of left-aligned.
            PaneHeader(leadingPadding: DS.Gutter.sidebar + DS.Space.sm,
                       trailingPadding: DS.Space.md) {
                PaneTitle("Projects", count: visibleCount)
            }

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
            // Footer is three stacked rows on a single block: CPU on top,
            // MEM (CPU/MEM are owned by `ResourceBar`'s VStack), then the
            // action icons. All three buttons are icon-only — the labels
            // were redundant given the tooltips, and dropping them lets
            // the icons sit on a single tight row.
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ResourceBar()
                HStack(spacing: DS.Space.sm) {
                    SidebarProjectAddButton(createProject: createProject,
                                            addProject: addProject)
                    SidebarFooterButton(label: "",
                                        systemName: "folder.badge.plus",
                                        fillsWidth: true,
                                        help: "New Group",
                                        action: startNewGroup)
                    // Direct-action update button — no dropdown. Settings
                    // stays reachable via ⌘, and the standard "AgenticIDE
                    // → Settings…" menu-bar item, so we don't lose access
                    // by removing the gear menu from this footer.
                    SidebarFooterButton(label: "",
                                        systemName: "arrow.triangle.2.circlepath",
                                        fillsWidth: true,
                                        help: "Check for Updates",
                                        action: { updater.checkForUpdates() })
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
        }
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
        .dropDestination(for: String.self) { items, _ in
            let projectIds = items.filter { !$0.hasPrefix("group:") }
            moveProjects(from: projectIds, to: nil)
            return !projectIds.isEmpty
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
                               selectedProjectId = project.id
                               session.addWorkspace()
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
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    selectedProjectId = project.id
                }
            }
            .draggable(project.id.uuidString) {
                Label(project.name, systemImage: "folder.fill")
                    .padding(DS.Space.sm)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
            }
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

    private func moveProjects(from items: [String], to groupId: UUID?) {
        for raw in items {
            // Skip group payloads — only project UUIDs land here.
            if raw.hasPrefix("group:") { continue }
            guard let id = UUID(uuidString: raw) else { continue }
            store.setProjectGroup(projectId: id, groupId: groupId)
        }
    }

    /// Dispatches a drop on a group's section. Group payloads reorder; project
    /// payloads move into the group.
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
                store.setProjectGroup(projectId: pid, groupId: targetGroupId)
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

private struct SidebarFooterButton: View {
    let label: String
    let systemName: String
    let fillsWidth: Bool
    let help: String
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    /// True when this button has a visible text label. The icon-only path
    /// (no label, fillsWidth) shows just the icon centred in a stretched
    /// pill — used by the footer's three action buttons so they tile the
    /// row evenly.
    private var hasLabel: Bool { fillsWidth && !label.isEmpty }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: systemName)
                    .font(DS.Font.bodySemibold)
                if hasLabel {
                    Text(label)
                        .font(DS.Font.bodyMedium)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, hasLabel ? DS.Space.md : 0)
            .padding(.vertical, DS.Space.xs + 1)
            .frame(maxWidth: fillsWidth ? .infinity : nil,
                   alignment: hasLabel ? .leading : .center)
            // Pin an explicit height so the icon-only footer pills match the
            // menu pill exactly (the menu's borderlessButton style won't grow
            // from vertical padding, so both sides agree on a fixed height).
            .frame(width: fillsWidth ? nil : DS.Control.large,
                   height: DS.Control.large)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .fill(Color.primary.opacity(isPressed ? 0.16 : (isHovered ? 0.10 : 0.04)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.18 : 0.10), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.08), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: isPressed)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .help(help)
    }
}

private struct SidebarProjectAddButton: View {
    let createProject: () -> Void
    let addProject: () -> Void

    @State private var isHovered = false
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "plus")
                .font(DS.Font.bodySemibold)
                .frame(maxWidth: .infinity, minHeight: DS.Control.large, maxHeight: DS.Control.large)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.10 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovered ? 0.18 : 0.10), lineWidth: 0.5)
        )
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
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.sm) {
                if savedWorkspaceCount > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: DS.Icon.micro, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: DS.Tree.chevronColumn)
                }
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                Text(project.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }

            HStack(spacing: DS.Space.sm) {
                if savedWorkspaceCount > 0 {
                    Label(workspaceCountLabel, systemImage: "square.grid.2x2")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No activity")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, DS.Space.xxs)
    }

    private var workspaceCountLabel: String {
        savedWorkspaceCount == 1 ? "1 workspace" : "\(savedWorkspaceCount) workspaces"
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
                if !session.workspaces.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: DS.Icon.micro, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: DS.Tree.chevronColumn)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                Text(project.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                // Aggregate status dots across every running cell — collapsed
                // rows only. When expanded, each workspace row shows its own
                // dots, so a duplicate header indicator just crowds the title.
                if !isExpanded, !allRunningCells.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(allRunningCells) { cell in
                            Circle()
                                .fill(dotColor(for: cell.terminal?.status ?? .idle))
                                .frame(width: 7, height: 7) // status dot — keep tight
                                .help(dotHelp(for: cell))
                        }
                    }
                }
            }

            // Summary line — workspace count + live agent-work timer. Lives
            // below the title so the row height doesn't shift when expanding/
            // collapsing children. The timer counts up from the moment a cell
            // entered `.working` (set by agent hooks / terminal events) and
            // disappears — resetting — once the agent finishes.
            HStack(spacing: DS.Space.sm) {
                if !session.workspaces.isEmpty {
                    Label(workspaceCountLabel, systemImage: "square.grid.2x2")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let since = earliestWorkingSince {
                    if !session.workspaces.isEmpty {
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                    }
                    WorkingTimerLabel(since: since)
                }
                if session.workspaces.isEmpty {
                    Text("No activity")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                // Forces the HStack — and therefore the parent VStack — to
                // claim the full proposed width. Without it the summary line
                // stops at its content and the VStack reports a natural width
                // shorter than the parent, which is what was making the
                // outer blue tile end before the sidebar's right edge.
                Spacer(minLength: 0)
            }

            // Workspace children — only inserted into the layout when expanded.
            // Conditional rendering means the parent VStack doesn't reserve its
            // `spacing` slot when collapsed, so the blue tile's top/bottom
            // padding stay symmetric. The asymmetric leading inset reads as
            // nesting under the project; the small trailing inset keeps the
            // inner tiles off the outer tile's border.
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
                // Asymmetric on purpose: a clear hierarchy indent on the
                // leading side (so the row reads as a child of the project)
                // and a small breathing-room inset on the trailing side so
                // the row's blue tile doesn't bleed into the outer tile's
                // border. Roughly aligns with where the title text begins
                // (chevron + folder-icon column).
                .padding(.leading, DS.Space.lg + 2)
                .padding(.trailing, DS.Space.xs)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, DS.Space.xxs)
        .animation(.spring(response: 0.40, dampingFraction: 0.85), value: session.workspaces.map(\.id))
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }

    private var allRunningCells: [WorkspaceCell] {
        session.workspaces.flatMap { $0.runningCells }
    }

    private var workspaceCountLabel: String {
        let n = session.workspaces.count
        return n == 1 ? "1 workspace" : "\(n) workspaces"
    }

    /// Color for one cell's dot. Idle cells fall back to a muted neutral so the
    /// count still reads as "N running" — the active-status colours pop against
    /// that baseline.
    private func dotColor(for status: TerminalTabStatus) -> Color {
        if let info = TerminalStatusBadge.info(for: status) {
            return info.color
        }
        return Color.secondary.opacity(0.45)
    }

    /// Tooltip for one dot — names the cell so hovering disambiguates which
    /// terminal a coloured dot belongs to.
    private func dotHelp(for cell: WorkspaceCell) -> String {
        let title = cell.terminal?.title ?? cell.kind?.label ?? "Terminal"
        let label = TerminalStatusBadge.info(for: cell.terminal?.status ?? .idle)?.label ?? "Idle"
        return "\(title) — \(label)"
    }

    /// Start time of the longest-running working cell in this project, or nil
    /// when no agent is working. Multiple working cells collapse into one timer
    /// (the earliest start) so the row answers "how long has AI been busy here".
    private var earliestWorkingSince: Date? {
        allRunningCells
            .compactMap { $0.terminal?.status == .working ? $0.terminal?.workingSince : nil }
            .min()
    }
}

/// Live elapsed-time readout for a working agent. `TimelineView` re-renders
/// just this label once a second, so the rest of the sidebar doesn't pay for
/// the tick — and there's no shared runloop timer to manage.
private struct WorkingTimerLabel: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Label(Self.format(context.date.timeIntervalSince(since)),
                  systemImage: "timer")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(TerminalStatusBadge.info(for: .working)?.color ?? .secondary)
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
private struct WorkspaceChildRow: View {
    @Bindable var workspace: Workspace
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var draftName: String = ""
    @State private var pulseOpacity: Double = 1.0
    /// Guards against stacking `repeatForever` animations on the same property
    /// when both `.onAppear` and `.onChange` would otherwise call
    /// `withAnimation` in quick succession.
    @State private var isPulsing: Bool = false
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            leadingIcon

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
                Text("\(workspace.rows)×\(workspace.cols)")
                    .font(DS.Font.badge)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: DS.Space.xs)

            // Per-running-cell status dots — the at-a-glance multi-agent view.
            if !workspace.runningCells.isEmpty, !isEditing {
                HStack(spacing: 3) {
                    ForEach(workspace.runningCells) { cell in
                        Circle()
                            .fill(dotColor(cell.terminal?.status ?? .idle))
                            .frame(width: 6, height: 6) // status dot — keep tight
                            .help(dotHelp(cell))
                    }
                }
            }
            // Reserve close-button space so layout doesn't reflow on hover.
            Color.clear.frame(width: DS.Control.compact, height: DS.Control.badge)
        }
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
        .onChange(of: aggregateWorking) { _, working in
            updatePulse(working: working)
        }
        .onAppear {
            updatePulse(working: aggregateWorking)
        }
    }

    /// Leading glyph: a pulsing status dot when any cell is working / done /
    /// failed, otherwise the grid icon.
    @ViewBuilder
    private var leadingIcon: some View {
        if let info = TerminalStatusBadge.info(for: aggregateStatus) {
            Circle()
                .fill(info.color)
                .frame(width: 7, height: 7) // status dot — keep tight
                .frame(width: DS.Tree.iconColumn - 2)
                .opacity(aggregateWorking ? pulseOpacity : 1.0)
                .help(info.label)
        } else {
            Image(systemName: "square.grid.2x2")
                .font(DS.Font.control)
                .foregroundStyle(.secondary)
                .frame(width: DS.Tree.iconColumn - 2)
        }
    }

    /// Highest-priority status across the workspace's running cells:
    /// working > failed > completed > idle.
    private var aggregateStatus: TerminalTabStatus {
        let statuses = workspace.runningCells.compactMap { $0.terminal?.status }
        if statuses.contains(.working) { return .working }
        if statuses.contains(.failed) { return .failed }
        if statuses.contains(.completed) { return .completed }
        return .idle
    }

    private var aggregateWorking: Bool { aggregateStatus == .working }

    private func dotColor(_ status: TerminalTabStatus) -> Color {
        TerminalStatusBadge.info(for: status)?.color ?? Color.secondary.opacity(0.45)
    }

    private func dotHelp(_ cell: WorkspaceCell) -> String {
        let title = cell.terminal?.title ?? cell.kind?.label ?? "Terminal"
        let label = TerminalStatusBadge.info(for: cell.terminal?.status ?? .idle)?.label ?? "Idle"
        return "\(title) — \(label)"
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

    /// Single entry point for starting/stopping the working-state pulse.
    /// Idempotent — repeated calls with the same `working` value short-circuit
    /// so a re-render of an already-pulsing row doesn't stack another
    /// `repeatForever` animation onto `pulseOpacity`.
    private func updatePulse(working: Bool) {
        guard working != isPulsing else { return }
        isPulsing = working
        if working {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulseOpacity = 0.35
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { pulseOpacity = 1.0 }
        }
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
