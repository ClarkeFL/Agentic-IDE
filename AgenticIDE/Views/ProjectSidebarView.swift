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
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let ungrouped = projects(in: nil)
                    if !ungrouped.isEmpty || !store.groups.isEmpty {
                        ungroupedSection(projects: ungrouped, hasGroups: !store.groups.isEmpty)
                    }

                    ForEach(store.sortedGroups) { group in
                        groupSection(group)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .background(.clear)
            .animation(.easeOut(duration: 0.12), value: hoveredDropKey)

            Divider()
            HStack(spacing: 6) {
                SidebarFooterButton(label: "Add Project",
                                    systemName: "plus",
                                    fillsWidth: true,
                                    help: "Add a project folder",
                                    action: addProject)

                SidebarFooterButton(label: "New Group",
                                    systemName: "folder.badge.plus",
                                    fillsWidth: false,
                                    help: "New Group",
                                    action: startNewGroup)

                SidebarFooterMenu(systemName: "gearshape",
                                  help: "Settings") {
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }
            .padding(8)
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
    private func groupHeader(_ group: ProjectGroup) -> some View {
        let isEmpty = projects(in: group.id).isEmpty
        let isHovered = hoveredGroupId == group.id

        HStack(spacing: 2) {
            Text(group.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)

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
        .frame(minHeight: 22)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.bottom, isEmpty ? 4 : 10)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredGroupId = group.id
            } else if hoveredGroupId == group.id {
                hoveredGroupId = nil
            }
        }
        .contextMenu {
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
        VStack(alignment: .leading, spacing: 2) {
            Text(hasGroups ? "Ungrouped" : "Projects")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.trailing, 8)
                .padding(.leading, 6)
                .padding(.bottom, projects.isEmpty ? 4 : 8)
                .modifier(DropZoneHighlight(active: hoveredDropKey == "ungrouped"))

            ForEach(projects) { project in
                projectRowItem(project)
            }
        }
        .padding(.bottom, 12)
        .dropDestination(for: String.self) { items, _ in
            let projectIds = items.filter { !$0.hasPrefix("group:") }
            moveProjects(from: projectIds, to: nil)
            return !projectIds.isEmpty
        } isTargeted: { entering in
            isTargetedBinding("ungrouped").wrappedValue = entering
        }
    }

    @ViewBuilder
    private func groupSection(_ group: ProjectGroup) -> some View {
        let groupProjects = self.projects(in: group.id)
        VStack(alignment: .leading, spacing: 2) {
            groupHeader(group)
                .modifier(DropZoneHighlight(active: hoveredDropKey == "group:\(group.id.uuidString)"))
                .draggable("group:\(group.id.uuidString)") {
                    Label(group.name, systemImage: "folder.fill.badge.gearshape")
                        .padding(6)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }

            ForEach(groupProjects) { project in
                projectRowItem(project)
            }
        }
        .padding(.bottom, 12)
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
                   onSelectTab: { id in session.activeTabId = id },
                   onCloseTab: { id in session.closeTab(id: id) },
                   onRenameTab: { id, newTitle in
                       guard let idx = session.tabs.firstIndex(where: { $0.id == id }) else { return }
                       let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
                       guard !trimmed.isEmpty else { return }
                       session.tabs[idx].title = trimmed
                       session.markDirty()
                   })
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
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
                    .padding(6)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
            .contextMenu {
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

    private func projects(in groupId: UUID?) -> [Project] {
        store.projects.filter { !$0.archived && $0.groupId == groupId }
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
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                if fillsWidth {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                }
                if fillsWidth {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, fillsWidth ? 8 : 0)
            .padding(.vertical, 5)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .frame(width: fillsWidth ? nil : 26, height: fillsWidth ? nil : 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isPressed ? 0.16 : (isHovered ? 0.10 : 0.04)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
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

private struct SidebarFooterMenu<MenuContent: View>: View {
    let systemName: String
    let help: String
    @ViewBuilder let content: () -> MenuContent

    @State private var isHovered = false

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.10 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isHovered ? 0.18 : 0.10), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help(help)
    }
}

private struct SidebarIconButton: View {
    let systemName: String
    let help: String
    let enabled: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? Color.primary : Color.primary.opacity(0.35))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(enabled && isHovered ? (isPressed ? 0.18 : 0.12) : 0.0))
                )
                .contentShape(Rectangle())
                .scaleEffect(isPressed ? 0.94 : 1.0)
                .animation(.easeOut(duration: 0.08), value: isHovered)
                .animation(.easeOut(duration: 0.08), value: isPressed)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { isHovered = $0 }
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
    let onSelectTab: (UUID) -> Void
    let onCloseTab: (UUID) -> Void
    let onRenameTab: (UUID, String) -> Void

    /// Drives a periodic refresh of the relative-time label so it ticks
    /// without showing seconds. 30s cadence is plenty when our smallest
    /// unit is "min."
    @State private var now: Date = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if !session.tabs.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                Text(project.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }

            // Summary line — always visible regardless of selection so the
            // row height doesn't shift when expanding/collapsing children.
            HStack(spacing: 6) {
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
            }

            // Expanded children — terminal rows under this project. We always
            // render the container but collapse it to height 0 when not
            // expanded so the row animates as a single unit (no fade-over of
            // the project title during collapse).
            VStack(spacing: 1) {
                ForEach(session.tabs) { tab in
                    TerminalChildRow(tab: tab,
                                     isActive: session.activeTabId == tab.id,
                                     onSelect: { onSelectTab(tab.id) },
                                     onClose: { onCloseTab(tab.id) },
                                     onRename: { newName in onRenameTab(tab.id, newName) })
                }
            }
            .padding(.top, isExpanded ? 6 : 0)
            .padding(.leading, 14)
            .frame(maxHeight: showChildren ? .infinity : 0, alignment: .top)
            .opacity(showChildren ? 1 : 0)
            .clipped()
        }
        .padding(.vertical, 2)
        .animation(.spring(response: 0.40, dampingFraction: 0.85), value: session.tabs.map(\.id))
        .onReceive(tick) { now = $0 }
    }

    private var showChildren: Bool {
        isExpanded && !session.tabs.isEmpty
    }

    private var tabCountLabel: String {
        let n = session.tabs.count
        return n == 1 ? "1 terminal" : "\(n) terminals"
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
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        // The selectable name area lives in an HStack with a fixed-width
        // trailing spacer so the title doesn't shift when the close button
        // appears on hover. The close button is overlaid on top so its taps
        // aren't fighting the row's onTapGesture for select/rename.
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            if isEditing {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .focused($nameFieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isEditing = false }
            } else {
                Text(tab.title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
            // Reserve close-button space so layout doesn't reflow on hover.
            Color.clear.frame(width: 18, height: 16)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(minHeight: 22)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
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
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.10))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 7)
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
}
