import Foundation
import Observation

/// In-memory state for an active project: its open tabs and which one is
/// focused. Created lazily by SessionManager on first activation, retained
/// for the rest of the app's lifetime so terminals keep running across
/// project switches.
@Observable
final class ProjectSession: Identifiable {
    let projectId: UUID
    var tabs: [TerminalTab] = []
    var activeTabId: UUID?

    init(projectId: UUID) {
        self.projectId = projectId
    }

    var activeTab: TerminalTab? {
        guard let id = activeTabId else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    func addTab(_ tab: TerminalTab) {
        tabs.append(tab)
        activeTabId = tab.id
    }

    func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        if activeTabId == id {
            // Pick the neighbor: previous if any, else next, else nil.
            if !tabs.isEmpty {
                let newIdx = max(0, idx - 1)
                activeTabId = tabs[newIdx].id
            } else {
                activeTabId = nil
            }
        }
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabId = tabs[index].id
    }
}
