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
    /// True while the window is in macOS fullscreen. The panes always run to
    /// the very top of the window now; this only controls whether the sidebar
    /// header reserves a leading inset for the floating traffic lights
    /// (windowed) or reclaims it (fullscreen hides them).
    @State private var isFullScreen = false
    /// Agent browser panes. Mode visibility is mirrored into
    /// `browserModeActive` so SwiftUI always re-renders on exit (relying only
    /// on `@State` + `@Observable` singleton was missing updates and leaving
    /// people stuck in browser view).
    private var browsers: BrowserManager { BrowserManager.shared }
    @State private var browserModeActive = false

    var body: some View {
        ZStack {
            if browserModeActive {
                // Slides in over a stationary grid and off again to reveal it
                // (the grid branch below uses .identity so it never travels).
                BrowserModeView(manager: browsers,
                                reserveTrafficLights: !isFullScreen,
                                onRequestExit: { exitBrowserMode() })
                    .transition(.move(edge: .trailing))
                    .zIndex(5)
            } else {
                // Full-width grid; browser picker is a hover drawer on the
                // trailing edge (no permanent chrome — ⌘B opens full mode).
                mainContent
                    .transition(.identity)
                    .overlay(alignment: .trailing) {
                        BrowserEdgeDrawer(
                            manager: browsers,
                            projectSession: selectedProjectSession,
                            onSelect: { session in
                                browsers.focusedId = session.id
                                enterBrowserMode()
                            },
                            onStartBrowser: {
                                startBrowserForSelection()
                            }
                        )
                    }
            }
            if showAsk {
                AskOverlay(isPresented: $showAsk)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        // Always install on the root — not only mainContent.onAppear.
        // When a browser workspace is restored first, mainContent never
        // mounts and background-drag stayed ON, so the top bar only dragged.
        .background(WindowChromeFixer())
        .onAppear { disableWindowBackgroundDrag() }
        .onChange(of: browserModeActive) { _, _ in
            disableWindowBackgroundDrag()
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
        .onReceive(NotificationCenter.default.publisher(for: .toggleBrowser)) { _ in
            // ⌘B flips browser ↔ grid.
            if browserModeActive {
                exitBrowserMode()
            } else {
                let projectSession = selectedProjectId.flatMap { sessions.liveSession(for: $0) }
                    ?? selectedProjectId.flatMap { sessions.session(for: $0) }
                browsers.expandMode(projectSession: projectSession)
                // expandMode/openManual post browserModeDidChange → enter via below
                if browsers.isModeActive { browserModeActive = true }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserModeDidChange)) { note in
            let active = (note.object as? Bool) ?? browsers.isModeActive
            browserModeActive = active
            disableWindowBackgroundDrag()
        }
        // Expand/collapse of browser mode.
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: browserModeActive)
    }

    private func enterBrowserMode() {
        browsers.setModeActive(true)
        browserModeActive = true
        disableWindowBackgroundDrag()
    }

    private func exitBrowserMode() {
        browsers.collapseMode()
        browserModeActive = false
    }

    /// Session for the sidebar selection (live if already materialised).
    private var selectedProjectSession: ProjectSession? {
        guard let id = selectedProjectId else { return nil }
        return sessions.liveSession(for: id) ?? sessions.session(for: id)
    }

    /// Open a browser for the selected project's active workspace (drawer empty state).
    private func startBrowserForSelection() {
        let projectSession = selectedProjectSession
        if let projectSession, let ws = projectSession.activeWorkspace {
            browsers.openManual(from: ws, projectSession: projectSession)
            browserModeActive = browsers.isModeActive
        } else {
            browsers.expandMode(projectSession: projectSession)
            if browsers.isModeActive { browserModeActive = true }
        }
        disableWindowBackgroundDrag()
    }

    /// Split view + every long-lived modifier. Extracted so the body's
    /// outer ZStack stays small enough for SwiftUI's type checker — the
    /// previous inline version tripped the "unable to type-check in
    /// reasonable time" budget once the AskOverlay branch was added.
    private var mainContent: some View {
        // Must run before `splitView` is first constructed so pane2's
        // @State initialValue reads the migrated floor, not a stale 300–560.
        let _ = Self.migrateExplorerWidthIfNeeded()
        return splitView
            // The title bar is hidden and the panes own the whole window
            // height — the sidebar header hosts the traffic lights.
            .ignoresSafeArea(.container, edges: .top)
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

    /// `.hiddenTitleBar` turns the content view into a window-drag surface
    /// (`isMovableByWindowBackground` defaults to true). That steals mouseDown
    /// from every toolbar control. Always force it off.
    private func disableWindowBackgroundDrag() {
        for window in NSApp.windows {
            window.isMovableByWindowBackground = false
        }
    }

    /// Pulled out of `body` because the four-pane initialiser plus its
    /// `.frame(...).onAppear...` modifier chain blew past SwiftUI's
    /// type-inference budget when written inline.
    /// Floor (and default) width of the folder pane — snug to the git
    /// footer button strip. The pane opens here and can only be dragged
    /// wider (up to `explorerMaxWidth`), never narrower.
    private static let explorerMinWidth: CGFloat =
        6 * DS.Control.large + 5 * DS.Space.xs + 2 * DS.Space.sm  // 192
    private static let explorerMaxWidth: CGFloat = 360
    /// One-shot: drop pre-float-editor saves (300–560) that kept the
    /// folder column fat after the tree became tree-only.
    private static let explorerWidthMigratedKey = "AgenticIDE.ExplorerTreeOnlyWidthMigrated"

    private var splitView: some View {
        PersistentSplitView(
            autosaveName: "AgenticIDE.MainSplit",
            pane1Min: 160, pane1Initial: 200, pane1Max: 360,
            // Pane 2 is tree-only. Opens at min; drag only widens. The
            // editor floats over the grid so this column never grows for
            // editing on its own.
            pane2Min: Self.explorerMinWidth,
            pane2Initial: Self.explorerMinWidth,
            pane2Max: Self.explorerMaxWidth,
            pane2Collapsed: fileTreeCollapsed,
            onExpandPane2: {
                withAnimation(.easeInOut(duration: 0.18)) { fileTreeCollapsed = false }
            },
            // nil after the one-shot migration below — leave user drag alone.
            pane2PreferredWidth: nil,
            pane3Min: 0,
            // Pane 3 is unused — the editor floats over pane 4 now.
            // Keeping it always-collapsed makes pane 4 (the workspace) elastic.
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

    // MARK: - Pane 1: Sidebar

    @ViewBuilder
    private var sidebarPane: some View {
        ProjectSidebarView(selectedProjectId: $selectedProjectId,
                           reserveTrafficLights: !isFullScreen)
            .environment(store)
            .environment(sessions)
    }

    // MARK: - Pane 2: Explorer (file tree only)

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

    // MARK: - Pane 4: Terminals + floating file editor

    @ViewBuilder
    private var terminalsPane: some View {
        if let project = activeProject {
            WorkspaceWithFloatingEditor(
                project: project,
                editor: editors.session(for: project.id),
                gitWatcher: gitWatchers.watcher(for: project.id, rootPath: project.path)
            )
            .environment(store)
            .environment(sessions)
            .id(project.id)
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
            .background(DS.Surface.app)
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
        .background(DS.Surface.app)
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

    /// Once: pin the folder pane to its floor. Old tree+editor layout
    /// persisted 300–560pt widths; with a floating editor those look wrong.
    /// After this, min stays the floor and drag only widens (still saved).
    @discardableResult
    private static func migrateExplorerWidthIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: explorerWidthMigratedKey) else { return false }
        defaults.set(Double(explorerMinWidth),
                     forKey: "AgenticIDE.MainSplit.pane2Width")
        defaults.set(true, forKey: explorerWidthMigratedKey)
        return true
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

// MARK: - Workspace + floating editor

/// Grid always fills the pane; when a file is open the editor floats on top
/// so the workspace never shrinks. Isolated so `@Bindable` tracks tab
/// open/close without MainWindow needing to observe every session.
private struct WorkspaceWithFloatingEditor: View {
    let project: Project
    @Bindable var editor: EditorSession
    @Bindable var gitWatcher: GitStatusWatcher

    var body: some View {
        ZStack {
            ProjectWorkspaceView(project: project)

            if editor.hasOpenFile {
                FloatingEditorOverlay(
                    project: project,
                    editor: editor,
                    gitWatcher: gitWatcher
                )
                // Slide out from the folder pane (leading), not from the
                // far right of the window.
                .transition(.move(edge: .leading).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: editor.hasOpenFile)
    }
}

// MARK: - Window chrome

/// Attaches to the SwiftUI hierarchy so we can reach the real `NSWindow` and
/// keep `isMovableByWindowBackground` off even when browser mode is restored
/// before `mainContent` mounts.
private struct WindowChromeFixer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = WindowChromeFixerView()
        view.disableBackgroundDrag()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowChromeFixerView)?.disableBackgroundDrag()
    }
}

private final class WindowChromeFixerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        disableBackgroundDrag()
    }

    func disableBackgroundDrag() {
        window?.isMovableByWindowBackground = false
        for w in NSApp.windows {
            w.isMovableByWindowBackground = false
            // Paint the window chrome with the Grok canvas so gaps behind
            // the SwiftUI hierarchy (title-bar strip, etc.) match the app.
            w.backgroundColor = DS.Surface.appNSColor
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }
}
