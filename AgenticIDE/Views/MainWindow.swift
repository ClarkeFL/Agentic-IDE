import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionManager.self) private var sessions
    @Environment(EditorSessionManager.self) private var editors
    @Environment(GitStatusWatcherStore.self) private var gitWatchers
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
    }

    /// Split view + every long-lived modifier. Extracted so the body's
    /// outer ZStack stays small enough for SwiftUI's type checker — the
    /// previous inline version tripped the "unable to type-check in
    /// reasonable time" budget once the AskOverlay branch was added.
    private var mainContent: some View {
        splitView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(activeProject?.name ?? "Agentic IDE")
            .onAppear {
                restoreSelection()
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
    }

    /// Pulled out of `body` because the four-pane initialiser plus its
    /// `.frame(...).onAppear...` modifier chain blew past SwiftUI's
    /// type-inference budget when written inline.
    private var splitView: some View {
        PersistentSplitView(
            autosaveName: "AgenticIDE.MainSplit",
            pane1Min: 160, pane1Initial: 200, pane1Max: 360,
            // Pane 2 is now the Explorer card (file tree + editor). It needs to
            // grow wide enough to hold both comfortably, so the max is large.
            pane2Min: 200, pane2Initial: 300, pane2Max: 1100,
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
            pane1: { sidebarPane },
            pane2: { explorerPane },
            pane3: { Color.clear },
            pane4: { terminalsPane }
        )
        .animation(.easeInOut(duration: 0.18), value: fileTreeCollapsed)
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

    @ViewBuilder
    private var terminalsPane: some View {
        if let project = activeProject {
            ProjectWorkspaceView(project: project)
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
