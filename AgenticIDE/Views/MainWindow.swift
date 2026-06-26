import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @Environment(EditorSessionManager.self) private var editors
    @Environment(GitStatusWatcherStore.self) private var gitWatchers
    @Environment(LaunchToolStore.self) private var launchTools
    @AppStorage("currentProjectId") private var currentProjectIdString: String = ""

    @State private var selectedProjectId: UUID?
    /// Owns the Full Disk Access probe + onboarding sheet. Local to
    /// MainWindow because no other view needs to read the status today.
    @State private var fda = FullDiskAccessGate()
    @State private var showFDAOnboarding = false
    /// Flips true after the first onAppear runs the FDA propagation-window
    /// probe loop. `.onAppear` fires on every scene-restoration / window-
    /// rebuild, but the 6×250ms re-probe only makes sense once per process
    /// launch — the propagation window is a fresh-launch race, not a
    /// re-entry race.
    @State private var didEvaluateFDA = false
    /// Drives the Ask overlay slide-in. Toggled by the ⌘⇧A menu command via
    /// the `.toggleAskOverlay` notification.
    @State private var showAsk = false
    /// Collapses pane ② (file tree) into a thin reopen rail. Persisted so the
    /// choice survives relaunch. Toggled by the ⌘⌥B command (`.toggleFileTree`)
    /// and the file-tree header's collapse button.
    @AppStorage("fileTreeCollapsed") private var fileTreeCollapsed = false
    /// Shows pane ⑤ — the per-project Notes scratchpad (notes.md). Persisted so
    /// the choice survives relaunch. Toggled by ⌘⇧N (`.toggleNotes`), the
    /// workspace header's note button, and the pane's own close button.
    @AppStorage("notesPaneOpen") private var notesPaneOpen = false
    /// True while the window is in macOS fullscreen. Windowed: keep the top
    /// safe area so the cards sit below the title bar and the floating traffic
    /// lights get their own strip. Fullscreen: no title bar, so reclaim the top
    /// for the cards (`ignoresSafeArea(.top)`).
    @State private var isFullScreen = false

    var body: some View {
        ZStack {
            mainContent
            if showAsk {
                AskOverlay(isPresented: $showAsk)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleAskOverlay)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showAsk.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleFileTree)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                fileTreeCollapsed.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleNotes)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                notesPaneOpen.toggle()
            }
        }
    }

    /// Split view + every long-lived modifier. Extracted so the body's
    /// outer ZStack stays small enough for SwiftUI's type checker — the
    /// previous inline version tripped the "unable to type-check in
    /// reasonable time" budget once the AskOverlay branch was added.
    private var mainContent: some View {
        splitView
            // Windowed → keep the top safe area so the cards sit below the
            // title-bar strip (the traffic lights get their own room).
            // Fullscreen → no title bar, so reclaim the top for the cards.
            .ignoresSafeArea(.container, edges: isFullScreen ? .top : [])
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(activeProject?.name ?? "Agentic IDE")
            .onAppear {
                syncFullScreenState()
                restoreSelection()
                // Start the local agent bridge (cell → cell control/observe).
                // Idempotent; needs the session manager to resolve cells.
                AgentBridge.shared.start(sessions: sessions, store: store, launchTools: launchTools)
                if !didEvaluateFDA {
                    didEvaluateFDA = true
                    evaluateFullDiskAccess()
                }
            }
            .onChange(of: selectedProjectId) { _, new in
                currentProjectIdString = new?.uuidString ?? ""
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers)
            }
            .sheet(isPresented: $showFDAOnboarding) {
                FullDiskAccessOnboarding(gate: fda, isPresented: $showFDAOnboarding)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
                isFullScreen = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
                isFullScreen = false
            }
    }

    /// Best-effort initial read of the window's fullscreen state — the
    /// enter/exit notifications cover every change after launch, but a window
    /// restored straight into fullscreen never fires one.
    private func syncFullScreenState() {
        if let window = NSApp.windows.first(where: { $0.isVisible }) {
            isFullScreen = window.styleMask.contains(.fullScreen)
        }
    }

    /// Pulled out of `body` because the four-pane initialiser plus its
    /// `.frame(...).onAppear...` modifier chain blew past SwiftUI's
    /// type-inference budget when written inline.
    private var splitView: some View {
        PersistentSplitView(
            autosaveName: "AgenticIDE.MainSplit",
            pane1Min: 160, pane1Initial: 200, pane1Max: 360,
            // Pane 2 is now the Explorer card (file tree + editor). The min is
            // raised while a file is open so the workspace pane can't shrink the
            // editor below a usable width; the max is capped to the folder-view
            // width when no file is open (a bare tree can't usefully be wider)
            // and only opens up once the editor needs room.
            pane2Min: explorerMinWidth, pane2Initial: 300, pane2Max: explorerMaxWidth,
            pane2Collapsed: fileTreeCollapsed,
            onExpandPane2: {
                withAnimation(.easeInOut(duration: 0.18)) { fileTreeCollapsed = false }
            },
            // Widen the Explorer to a comfortable editing width when a file is
            // open; shrink back to a tree-only width when none are.
            pane2PreferredWidth: explorerPreferredWidth,
            pane3Min: 0,
            // Pane 3 is unused — the editor lives inside the Explorer card now.
            // Keeping it always-collapsed makes pane 4 (the workspace) elastic,
            // so the workspace takes whatever width is left.
            pane3Collapsed: true,
            pane4Min: 540, pane4Initial: 720, pane4Max: 1400,
            // Pane 5 is the optional Notes scratchpad on the far right.
            // Collapsed (removed) unless opened and a project is selected.
            pane5Min: 240, pane5Initial: 340, pane5Max: 680,
            pane5Collapsed: !(notesPaneOpen && fileAccessProject != nil),
            pane1: { sidebarPane },
            pane2: { explorerPane },
            pane3: { Color.clear },
            pane4: { terminalsPane },
            pane5: { notesPane }
        )
        .animation(.easeInOut(duration: 0.18), value: fileTreeCollapsed)
        .animation(.easeInOut(duration: 0.18), value: notesPaneOpen)
    }

    /// Target width for the Explorer pane: wide enough to edit comfortably when
    /// a file is open, narrow (tree only) when none are. `onChange` in the split
    /// view animates to this; it never fires on first render, so a persisted
    /// width still wins on launch.
    private var explorerPreferredWidth: CGFloat? {
        guard let project = fileAccessProject else { return nil }
        let hasFile = !editors.session(for: project.id).tabs.isEmpty
        return hasFile ? 560 : 300
    }

    /// Lower bound for the Explorer pane. While a file is open it can't shrink
    /// below tree + a usable editor width, so dragging the workspace divider
    /// (or a narrow persisted width on launch) can never crush the editor.
    private var explorerMinWidth: CGFloat {
        guard let project = fileAccessProject else { return 200 }
        return editors.session(for: project.id).tabs.isEmpty ? 200 : 480
    }

    /// Upper bound for the Explorer pane. With no file open it's just the folder
    /// tree, so cap it at the tree's max width (240) — dragging wider only makes
    /// an empty card. With a file open the editor needs room, so let it grow.
    private var explorerMaxWidth: CGFloat {
        guard let project = fileAccessProject else { return 240 }
        return editors.session(for: project.id).tabs.isEmpty ? 240 : 1100
    }

    // MARK: - Pane 1: Sidebar

    @ViewBuilder
    private var sidebarPane: some View {
        ProjectSidebarView(selectedProjectId: $selectedProjectId)
            .environment(store)
            .environment(sessions)
    }

    // MARK: - Pane 2: Explorer (file tree + editor)

    @ViewBuilder
    private var explorerPane: some View {
        if let project = fileAccessProject {
            ExplorerView(project: project,
                         editor: editors.session(for: project.id),
                         gitWatcher: gitWatchers.watcher(for: project.id, rootPath: project.path))
                .id(project.id)
        } else {
            paneEmptyState(systemImage: "folder",
                           text: "Select a project to browse its files.")
        }
    }

    // MARK: - Pane 4: Terminals

    /// True when the Notes pane (⑤) is actually on screen to the right of the
    /// workspace. Mirrors the `pane5Collapsed` condition so the workspace card
    /// can drop its trailing window-edge margin and let the divider be the seam.
    private var notesPaneVisible: Bool {
        notesPaneOpen && fileAccessProject != nil
    }

    @ViewBuilder
    private var terminalsPane: some View {
        if let project = activeProject {
            ProjectWorkspaceView(project: project,
                                 trailingInset: notesPaneVisible ? 0 : DS.Space.md)
                .environment(store)
                .environment(sessions)
        } else if store.projects.filter({ !$0.archived }).isEmpty {
            VStack(spacing: DS.Space.lg) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: DS.Icon.welcome, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Add a project to get started")
                    .font(.title3).foregroundStyle(.secondary)
                Text("Drag a folder onto the window or click + Add Project.")
                    .font(.subheadline).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            paneEmptyState(systemImage: "terminal",
                           text: "Select a project to launch terminals.")
        }
    }

    // MARK: - Pane 5: Notes

    @ViewBuilder
    private var notesPane: some View {
        if let project = fileAccessProject {
            NotesPanel(project: project,
                       onClose: {
                           withAnimation(.easeInOut(duration: 0.18)) { notesPaneOpen = false }
                       })
                .id(project.id)
        } else {
            Color.clear
        }
    }

    // MARK: - Helpers

    private func paneEmptyState(systemImage: String, text: String) -> some View {
        VStack(spacing: DS.Space.md) {
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
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var activeProject: Project? {
        guard let id = selectedProjectId else { return nil }
        return store.projects.first(where: { $0.id == id && !$0.archived })
    }

    /// Project handed to file-touching subviews (the file tree, editor,
    /// terminals). Returns `nil` while the FDA onboarding sheet is up so
    /// the panes don't immediately fire per-folder TCC prompts on top of
    /// our own sheet.
    private var fileAccessProject: Project? {
        if fda.status == .denied && !fda.skippedThisBuild { return nil }
        return activeProject
    }

    /// Re-probes FDA on appear and shows the onboarding sheet when the user
    /// hasn't been granted access and hasn't already skipped this build.
    /// Cheap to call repeatedly — the probe is just a `FileHandle` open.
    ///
    /// When the app is relaunched right after the user toggled FDA in System
    /// Settings, TCC sometimes hasn't propagated the new grant to our just-
    /// spawned process by the time the first probe runs — the result is the
    /// onboarding sheet showing again on a freshly-permitted launch. A short
    /// re-probe loop covers the propagation window so we don't bother the
    /// user a second time.
    private func evaluateFullDiskAccess() {
        fda.refresh()
        guard fda.status != .granted else { return }
        if fda.skippedThisBuild { return }

        Task { @MainActor in
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                fda.refresh()
                if fda.status == .granted { return }
            }
            if fda.status == .denied && !fda.skippedThisBuild {
                showFDAOnboarding = true
            }
        }
    }

    private func restoreSelection() {
        let visible = store.projects.filter { !$0.archived }
        if let id = UUID(uuidString: currentProjectIdString),
           visible.contains(where: { $0.id == id }) {
            selectedProjectId = id
        } else {
            selectedProjectId = visible.first?.id
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else { continue }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      isDir.boolValue else { return }
                Task { @MainActor in
                    let project = store.add(folder: url)
                    selectedProjectId = project.id
                }
            }
            handled = true
        }
        return handled
    }
}
