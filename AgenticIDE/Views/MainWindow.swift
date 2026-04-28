import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @Environment(ProjectStore.self) private var store
    @Environment(SessionManager.self) private var sessions
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

    var body: some View {
        PersistentSplitView(
            autosaveName: "AgenticIDE.MainSplit",
            leading: {
                ProjectSidebarView(selectedProjectId: $selectedProjectId)
                    .environment(store)
                    .environment(sessions)
            },
            center: {
                workspaceColumn
                    .environment(store)
                    .environment(sessions)
            },
            trailing: {
                RightInspectorView(project: fileAccessProject)
                    .environment(store)
                    .environment(sessions)
            }
        )
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

    @ViewBuilder
    private var workspaceColumn: some View {
        if let project = activeProject {
            ProjectWorkspaceView(project: project)
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
            VStack(spacing: DS.Space.md) {
                Text("Select a project")
                    .font(.title3).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var activeProject: Project? {
        guard let id = selectedProjectId else { return nil }
        return store.projects.first(where: { $0.id == id && !$0.archived })
    }

    /// Project handed to file-touching subviews (the right inspector's
    /// git-status poll, file listing, etc). Returns `nil` while the FDA
    /// onboarding sheet is up so the inspector doesn't immediately fire
    /// per-folder TCC prompts (Documents / Desktop / Downloads) on top
    /// of our own sheet — competing dialogs were the visible bug.
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
