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
    /// Single shared "now" tick fed to every project row's relative-time
    /// label. Replaces the per-row Timer.publish that used to spin one
    /// main-runloop timer per visible project.
    @State private var now: Date = Date()
    private let nowTick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

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
            // Leading inset clears the macOS traffic-light buttons (the
            // window uses `.hiddenTitleBar`, so the lights now float on
            // top of this header).
            PaneHeader(leadingPadding: DS.Layout.trafficLightInset,
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
        .onReceive(nowTick) { now = $0 }
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
        let session = sessions.session(for: project.id)
        let isSelected = selectedProjectId == project.id
        ProjectRow(project: project,
                   session: session,
                   isExpanded: isSelected,
                   now: now,
                   onSelectTab: { id in session.activeTabId = id },
                   onCloseTab: { id in session.closeTab(id: id) },
                   onRenameTab: { id, newTitle in
                       guard let idx = session.tabs.firstIndex(where: { $0.id == id }) else { return }
                       let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
                       guard !trimmed.isEmpty else { return }
                       session.tabs[idx].title = trimmed
                       session.markDirty()
                   })
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

private struct ProjectRow: View {
    let project: Project
    @Bindable var session: ProjectSession
    let isExpanded: Bool
    /// Shared "now" injected by the sidebar's single timer. Drives the
    /// relative-time label without each row spinning its own runloop timer.
    let now: Date
    let onSelectTab: (UUID) -> Void
    let onCloseTab: (UUID) -> Void
    let onRenameTab: (UUID, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.sm) {
                if !session.tabs.isEmpty {
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
                // Per-terminal status dots, only on collapsed rows. When the
                // project is expanded the per-tab rows below already show
                // their own dot+label, so a duplicate header indicator just
                // crowds the title. Order matches tab order so the user can
                // map "third dot is green" to the third terminal in the list.
                if !isExpanded, !session.tabs.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(session.tabs) { tab in
                            Circle()
                                .fill(dotColor(for: tab.status))
                                .frame(width: 7, height: 7) // status dot — keep tight
                                .help(dotHelp(for: tab))
                        }
                    }
                }
            }

            // Summary line — terminal count + last-activity. Lives below the
            // title so the row height doesn't shift when expanding/collapsing
            // children. The status indicator used to live here too; it's now
            // promoted into the title row so the dot stays visible (and right-
            // aligned to the title) regardless of whether this line renders.
            HStack(spacing: DS.Space.sm) {
                if !session.tabs.isEmpty {
                    Label(tabCountLabel, systemImage: "rectangle.stack")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let at = project.lastActivityAt {
                    if !session.tabs.isEmpty {
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(formatRelative(at))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if session.tabs.isEmpty && project.lastActivityAt == nil {
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

            // Terminal children — only inserted into the layout when shown.
            // Conditional rendering (vs the old `.frame(maxHeight: 0)`)
            // means the parent VStack doesn't reserve its `spacing` slot
            // when collapsed, so the blue tile's top/bottom padding stay
            // symmetric.
            //
            // Horizontal inset is small + symmetric: just enough to read
            // as nested under the project, not so much that the inner blue
            // row is dwarfed inside the outer one. Aligns roughly with
            // where the title text sits (folder-icon column) for a clean
            // vertical edge running down the tile.
            if showChildren {
                VStack(spacing: 1) {
                    ForEach(session.tabs) { tab in
                        TerminalChildRow(tab: tab,
                                         isActive: session.activeTabId == tab.id,
                                         onSelect: { onSelectTab(tab.id) },
                                         onClose: { onCloseTab(tab.id) },
                                         onRename: { newName in onRenameTab(tab.id, newName) })
                    }
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
        .animation(.spring(response: 0.40, dampingFraction: 0.85), value: session.tabs.map(\.id))
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }

    private var showChildren: Bool {
        isExpanded && !session.tabs.isEmpty
    }

    private var tabCountLabel: String {
        let n = session.tabs.count
        return n == 1 ? "1 terminal" : "\(n) terminals"
    }

    /// Color for one terminal's dot on the collapsed row. Idle tabs fall back
    /// to a muted neutral so the user can still count "four terminals = four
    /// dots" — the active-status colours then pop against that baseline.
    private func dotColor(for status: TerminalTabStatus) -> Color {
        if let info = TerminalStatusBadge.info(for: status) {
            return info.color
        }
        return Color.secondary.opacity(0.45)
    }

    /// Tooltip for one dot — names the tab so hovering disambiguates which
    /// terminal a coloured dot belongs to.
    private func dotHelp(for tab: TerminalTab) -> String {
        let label = TerminalStatusBadge.info(for: tab.status)?.label ?? "Idle"
        return "\(tab.title) — \(label)"
    }

    /// Minutes/hours/days only — never seconds.
    private func formatRelative(_ date: Date) -> String {
        let diff = max(0, Int(now.timeIntervalSince(date)))
        if diff < 60 { return "just now" }
        let minutes = diff / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr" }
        let days = hours / 24
        return "\(days) d"
    }
}

/// One terminal row nested under a project. Click selects, hover reveals close,
/// double-click swaps the name into an inline TextField.
private struct TerminalChildRow: View {
    @Bindable var tab: TerminalTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var draftName: String = ""
    @State private var pulseOpacity: Double = 1.0
    /// Guards against stacking `repeatForever` animations on the same
    /// property when both `.onAppear` and `.onChange(of: tab.status)` would
    /// otherwise call `withAnimation` in quick succession (a working tab's
    /// row reappearing after a project switch is the common trigger).
    @State private var isPulsing: Bool = false
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        // The selectable name area lives in an HStack with a fixed-width
        // trailing spacer so the title doesn't shift when the close button
        // appears on hover. The close button is overlaid on top so its taps
        // aren't fighting the row's onTapGesture for select/rename.
        HStack(spacing: DS.Space.sm) {
            // Status dot replaces the generic terminal glyph when something
            // interesting is happening (working / completed /
            // failed) — keeps the row at the same height but communicates
            // state at a glance. When idle we fall back to the terminal icon.
            if let info = TerminalStatusBadge.info(for: tab.status) {
                Circle()
                    .fill(info.color)
                    .frame(width: 7, height: 7) // status dot — keep tight
                    .frame(width: DS.Tree.iconColumn - 2)
                    .opacity(tab.status == .working ? pulseOpacity : 1.0)
                    .help(info.label)
            } else {
                Image(systemName: "terminal")
                    .font(DS.Font.control)
                    .foregroundStyle(.secondary)
                    .frame(width: DS.Tree.iconColumn - 2)
            }

            if isEditing {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: DS.FontSize.body, weight: isActive ? .semibold : .regular))
                    .focused($nameFieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isEditing = false }
            } else {
                HStack(spacing: DS.Space.xs + 1) {
                    if let info = TerminalStatusBadge.info(for: tab.status) {
                        Text(info.label)
                            .font(DS.Font.bodySemibold)
                            .foregroundStyle(info.color)
                            .lineLimit(1)
                    }
                    Text(tab.title)
                        .font(.system(size: DS.FontSize.body, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DS.Space.xs)
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
            .help("Close terminal")
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Rename…") { startRename() }
            Divider()
            Button("Close", role: .destructive) { onClose() }
        }
        .onChange(of: tab.status) { _, newValue in
            updatePulse(working: newValue == .working)
        }
        .onAppear {
            // Re-establish the pulse if the tab was already working when the
            // row appeared (e.g. after switching between projects).
            updatePulse(working: tab.status == .working)
        }
    }

    private func startRename() {
        draftName = tab.title
        isEditing = true
        DispatchQueue.main.async { nameFieldFocused = true }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { onRename(trimmed) }
        isEditing = false
    }

    /// Single entry point for starting/stopping the working-state pulse.
    /// Idempotent — repeated calls with the same `working` value short-
    /// circuit so a re-render of an already-pulsing row doesn't add
    /// another `repeatForever` animation onto `pulseOpacity`.
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
