import SwiftUI

/// Bottom strip of the workspace pane: one chip per configured server (green =
/// running, grey = stopped), plus Run all / Stop all / Edit. Clicking a running
/// chip jumps to its terminal in the "Servers" workspace; a stopped chip runs
/// just that one. When no servers are set up yet, shows a single setup button.
struct ServerBar: View {
    @Environment(ProjectStore.self) private var store
    let project: Project
    @Bindable var session: ProjectSession

    @State private var showEditor = false

    private var runner: ServerRunner {
        ServerRunner(project: project, session: session, store: store)
    }

    var body: some View {
        let running = runner.runningLabels()
        HStack(spacing: DS.Space.sm) {
            if project.servers.isEmpty {
                Button { showEditor = true } label: {
                    Label("Set up servers", systemImage: "server.rack")
                        .font(DS.Font.control)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(project.servers) { server in
                    ServerChip(name: server.label,
                               isRunning: running.contains(server.label)) {
                        if running.contains(server.label) { runner.jump(to: server.label) }
                        else { runner.run([server]) }
                    }
                }
                Spacer(minLength: DS.Space.sm)
                Button { runner.run(project.servers) } label: {
                    Label("Run all", systemImage: "play.fill").font(DS.Font.control)
                }
                .buttonStyle(.plain)
                .help("Run all servers in the Servers workspace")
                Menu {
                    Button("Run all") { runner.run(project.servers) }
                    Button("Stop all") { runner.stopAll() }
                    Divider()
                    Button("Edit servers…") { showEditor = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(DS.Font.control)
                        .frame(width: DS.Control.compact, height: DS.Control.compact)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, DS.Space.lg - 2)
        .frame(height: DS.Control.header)
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $showEditor) {
            ServersEditor(initial: project.servers,
                          onSave: { updated in
                              store.updateServers(projectId: project.id, updated)
                              showEditor = false
                          },
                          onCancel: { showEditor = false })
        }
    }
}

private struct ServerChip: View {
    let name: String
    let isRunning: Bool
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                Circle()
                    .fill(isRunning ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(name)
                    .font(DS.Font.control)
                    .lineLimit(1)
            }
            .padding(.horizontal, DS.Space.sm)
            .frame(height: DS.Control.compact)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(Color.primary.opacity(hover ? 0.10 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(isRunning ? "Running — click to jump to it" : "Stopped — click to run")
    }
}

/// Add/edit/remove rows for the project's servers. Reuses `QuickLaunch`
/// (label = name, command = shell command).
private struct ServersEditor: View {
    @State private var rows: [QuickLaunch]
    let onSave: ([QuickLaunch]) -> Void
    let onCancel: () -> Void

    init(initial: [QuickLaunch],
         onSave: @escaping ([QuickLaunch]) -> Void,
         onCancel: @escaping () -> Void) {
        _rows = State(initialValue: initial.isEmpty
            ? [QuickLaunch(label: "", command: "")]
            : initial)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("Servers").font(.headline)
            Text("Each runs in the project root via your login shell. Run them and they open in a dedicated “Servers” workspace.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach($rows) { $row in
                HStack(spacing: DS.Space.sm) {
                    TextField("name", text: $row.label)
                        .frame(width: 90)
                    TextField("command e.g. npm run dev", text: $row.command)
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
                .textFieldStyle(.roundedBorder)
            }

            Button {
                rows.append(QuickLaunch(label: "", command: ""))
            } label: {
                Label("Add server", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .font(DS.Font.control)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save") { onSave(cleaned) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 440)
    }

    /// Trim each row and drop the blanks so empty rows never persist.
    private var cleaned: [QuickLaunch] {
        rows.compactMap { row in
            let name = row.label.trimmingCharacters(in: .whitespaces)
            let cmd = row.command.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !cmd.isEmpty else { return nil }
            return QuickLaunch(id: row.id, label: name, command: cmd)
        }
    }
}
