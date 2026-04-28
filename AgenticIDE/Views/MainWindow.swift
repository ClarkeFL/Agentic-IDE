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
                RightInspectorView(project: activeProject)
                    .environment(store)
                    .environment(sessions)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(activeProject?.name ?? "Agentic IDE")
        .onAppear {
            restoreSelection()
            evaluateFullDiskAccess()
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
            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Add a project to get started")
                    .font(.title3).foregroundStyle(.secondary)
                Text("Drag a folder onto the window or click + Add Project.")
                    .font(.subheadline).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
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

    /// Re-probes FDA on appear and shows the onboarding sheet when the user
    /// hasn't been granted access and hasn't already skipped this build.
    /// Cheap to call repeatedly — the probe is just a `FileHandle` open.
    private func evaluateFullDiskAccess() {
        fda.refresh()
        if fda.status == .denied && !fda.skippedThisBuild {
            showFDAOnboarding = true
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
