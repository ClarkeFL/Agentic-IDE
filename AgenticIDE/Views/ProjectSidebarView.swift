import AppKit
import SwiftUI

struct ProjectSidebarView: View {
    @Environment(ProjectStore.self) private var store
    @Binding var selectedProjectId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedProjectId) {
                Section {
                    ForEach(store.projects.filter { !$0.archived }) { project in
                        ProjectRow(project: project)
                            .tag(project.id)
                            .contextMenu {
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([project.path])
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
                }
            }
            .listStyle(.sidebar)

            Divider()
            Button(action: addProject) {
                Label("Add Project", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
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

private struct ProjectRow: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                Text(project.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
            }
            if let cmd = project.lastActivityCommand {
                Text("$ \(cmd)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No activity")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let at = project.lastActivityAt {
                Text(at, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
