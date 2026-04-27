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
    var activeTabId: UUID? {
        didSet {
            saveHook?()
            clearStatusOnActiveTab()
        }
    }

    /// When the user opens a tab whose status is one of the "got your
    /// attention" states (completed / failed), drop it back to idle —
    /// they've now seen the indicator. Working stays put because the AI
    /// is still running and the indicator is still meaningful.
    private func clearStatusOnActiveTab() {
        guard let id = activeTabId,
              let tab = tabs.first(where: { $0.id == id }) else { return }
        switch tab.status {
        case .completed, .failed:
            tab.status = .idle
        case .idle, .working:
            break
        }
    }

    /// Called whenever tabs/active-tab change in a way that should be
    /// persisted. Set by SessionManager.
    @ObservationIgnored
    var saveHook: (() -> Void)?

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
        saveHook?()
    }

    func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }

        // Step 1: switch the active tab synchronously so the next render
        // shows a different terminal. The closed tab is now invisible
        // (opacity 0) even though it's still in the array.
        if activeTabId == id {
            if tabs.count > 1 {
                let newIdx = idx > 0 ? idx - 1 : idx + 1
                activeTabId = tabs[newIdx].id
            } else {
                activeTabId = nil
            }
        }

        // Step 2: defer the actual array removal + ghostty teardown to the
        // next runloop tick. The user-visible close is instant; the
        // NSViewRepresentable detachment + surface_free happen off the
        // critical path.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let i = self.tabs.firstIndex(where: { $0.id == id }) else { return }
            let removed = self.tabs[i]
            self.tabs.remove(at: i)
            removed.view.tearDown()
            self.saveHook?()
        }
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabId = tabs[index].id
    }

    /// Tell the manager that something not covered by a method (e.g. an
    /// inline title rename) just changed, and to flush state to disk.
    func markDirty() { saveHook?() }

    /// Installs the auto-rename hook on a tab's surface. When the user types
    /// a line and presses Return, if the tab still has its default launcher
    /// label (Claude / Codex / Run Server / shell), the title is replaced
    /// with a truncated version of that line. Manual renames are preserved
    /// because we only fire when the title still matches one of the defaults.
    func wireSmartRename(_ tab: TerminalTab) {
        tab.view.onUserSubmitLine = { [weak self, weak tab] line in
            guard let self, let tab else { return }
            let defaults: Set<String> = [
                "Claude", "Codex", "Run Server",
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
