import Foundation
import Observation

/// In-memory state for an active project: its workspaces and which one is
/// focused. Created lazily by SessionManager on first activation, retained for
/// the rest of the app's lifetime so terminals keep running across project (and
/// workspace) switches.
///
/// A project owns several `Workspace`s; each is a grid of `WorkspaceCell`s, and
/// each cell runs at most one `TerminalTab`. The live process lives in the
/// terminal's Ghostty surface and survives detaching the view (switching away
/// from the workspace), exactly like switching away from a project does.
@Observable
final class ProjectSession: Identifiable {
    let projectId: UUID
    var workspaces: [Workspace] = []
    var activeWorkspaceId: UUID? {
        didSet {
            saveHook?()
            clearStatusInActiveWorkspace()
        }
    }

    /// Called whenever workspace/cell state changes in a way that should be
    /// persisted. Set by SessionManager.
    @ObservationIgnored
    var saveHook: (() -> Void)?

    init(projectId: UUID) {
        self.projectId = projectId
    }

    var activeWorkspace: Workspace? {
        guard let id = activeWorkspaceId else { return workspaces.first }
        return workspaces.first(where: { $0.id == id }) ?? workspaces.first
    }

    /// When a workspace is opened, drop any "got your attention" status
    /// (completed / failed) on its cells back to idle — the user has now seen
    /// the result. Working stays put because the agent is still running.
    private func clearStatusInActiveWorkspace() {
        guard let ws = activeWorkspace else { return }
        for cell in ws.cells {
            guard let tab = cell.terminal else { continue }
            switch tab.status {
            case .completed, .failed: tab.status = .idle
            case .idle, .working: break
            }
        }
    }

    // MARK: - Workspaces

    /// Creates a workspace with the chosen grid size and makes it active. We
    /// deliberately do NOT auto-create a workspace on project selection — the
    /// user picks a layout first (see `ProjectWorkspaceView`'s chooser), and
    /// that choice calls this.
    @discardableResult
    func addWorkspace(layout: GridLayout = GridLayout(axis: .rows, counts: [1])) -> Workspace {
        let ws = Workspace(name: nextWorkspaceName())
        ws.apply(layout)
        workspaces.append(ws)
        activeWorkspaceId = ws.id
        saveHook?()
        return ws
    }

    func removeWorkspace(id: UUID) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let removed = workspaces.remove(at: idx)
        for cell in removed.cells { cell.terminal?.view.tearDown() }

        if activeWorkspaceId == id {
            let newIdx = idx > 0 ? idx - 1 : 0
            activeWorkspaceId = workspaces.indices.contains(newIdx) ? workspaces[newIdx].id : nil
        }
        saveHook?()
    }

    func renameWorkspace(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let ws = workspaces.first(where: { $0.id == id }) else { return }
        ws.name = trimmed
        saveHook?()
    }

    func resizeWorkspace(_ ws: Workspace, layout: GridLayout) {
        let dropped = ws.apply(layout)
        for cell in dropped { cell.terminal?.view.tearDown() }
        saveHook?()
    }

    func toggleZoom(cellId: UUID, in ws: Workspace) {
        ws.zoomedCellId = (ws.zoomedCellId == cellId) ? nil : cellId
        saveHook?()
    }

    // MARK: - Cells

    /// Place a freshly-built terminal into a cell, replacing whatever was there.
    /// The caller (the launcher view) owns building the `TerminalTab` via
    /// `PtyService` since that needs the project + store; the session wires the
    /// smart-rename hook and persists.
    func place(_ terminal: TerminalTab, icon: String?, in cell: WorkspaceCell) {
        cell.terminal?.view.tearDown()
        wireSmartRename(terminal)
        cell.icon = icon
        cell.terminal = terminal
        saveHook?()
    }

    /// Close a cell's program, returning it to the launcher.
    func closeCell(_ cell: WorkspaceCell) {
        guard let tab = cell.terminal else { return }
        cell.terminal = nil
        cell.icon = nil
        // If this cell was zoomed, the empty launcher has no restore button —
        // drop back to the grid so the user isn't stuck on a single empty cell.
        for ws in workspaces where ws.zoomedCellId == cell.id { ws.zoomedCellId = nil }
        // Defer teardown one runloop turn so the visible swap to the launcher
        // is instant and the Ghostty surface_free happens off the critical path.
        DispatchQueue.main.async { tab.view.tearDown() }
        saveHook?()
    }

    private func nextWorkspaceName() -> String {
        "Workspace \(workspaces.count + 1)"
    }

    /// Tell the manager that something not covered by a method (e.g. an inline
    /// rename) just changed, and to flush state to disk.
    func markDirty() { saveHook?() }

    /// Installs the auto-rename hook on a tab's surface. When the user types a
    /// line and presses Return, if the tab still has its default launcher label
    /// (Claude / Codex / Run Server / shell), the title is replaced with a
    /// truncated version of that line. Manual renames are preserved because we
    /// only fire when the title still matches one of the defaults.
    func wireSmartRename(_ tab: TerminalTab) {
        tab.view.onUserSubmitLine = { [weak self, weak tab] line in
            guard let self, let tab else { return }
            let defaults: Set<String> = [
                "Run Server", "Claude", "Codex",
                "zsh", "bash", "fish", "sh"
            ]
            guard defaults.contains(tab.title) else { return }
            let collapsed = line.replacingOccurrences(of: "\n", with: " ")
            let summary = String(collapsed.prefix(40))
                .trimmingCharacters(in: .whitespaces)
            guard !summary.isEmpty else { return }
            tab.title = summary
            self.markDirty()
        }
    }
}
