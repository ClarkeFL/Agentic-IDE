import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @Environment(ProjectStore.self) private var store
    @AppStorage("currentProjectId") private var currentProjectIdString: String = ""

    @State private var selectedProjectId: UUID?

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            ProjectSidebarView(selectedProjectId: $selectedProjectId)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } content: {
            workspaceColumn
                .navigationSplitViewColumnWidth(min: 480, ideal: 720)
        } detail: {
            RightInspectorPlaceholder(project: activeProject)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 480)
        }
        .navigationTitle(activeProject?.name ?? "Agentic IDE")
        .onAppear { restoreSelection() }
        .onChange(of: selectedProjectId) { _, new in
            currentProjectIdString = new?.uuidString ?? ""
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
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
