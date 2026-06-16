import SwiftUI

/// Settings → Launchers. Toggle which launch tiles appear in an empty workspace
/// cell, edit their command, and add / remove custom CLI tools.
struct LaunchersSettingsView: View {
    @Environment(LaunchToolStore.self) private var store
    @State private var editing: EditingTool?

    var body: some View {
        Form {
            Section {
                ForEach(store.tools) { tool in
                    LaunchToolRow(
                        tool: tool,
                        onToggle: { store.setEnabled(tool.id, $0) },
                        onEdit: { editing = EditingTool(tool: tool, isNew: false) },
                        onDelete: tool.isBuiltin ? nil : { store.remove(id: tool.id) })
                }
            } header: {
                Label("Launchers", systemImage: "square.grid.2x2")
            } footer: {
                Text("These are the tiles shown in an empty workspace cell. Toggle which appear, edit a command, or add your own CLI. Server runs each project's Run Server command; Terminal opens your login shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button {
                    editing = EditingTool(tool: LaunchTool(name: "", command: "", icon: "terminal"),
                                          isNew: true)
                } label: {
                    Label("Add Launcher…", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, DS.Space.md)
        .sheet(item: $editing) { item in
            LaunchToolEditor(
                tool: item.tool,
                isNew: item.isNew,
                onSave: { saved in
                    if item.isNew {
                        store.add(saved)
                    } else {
                        store.update(saved)
                    }
                    editing = nil
                },
                onCancel: { editing = nil })
        }
    }
}

private struct EditingTool: Identifiable {
    let id = UUID()
    var tool: LaunchTool
    var isNew: Bool
}

private struct LaunchToolRow: View {
    let tool: LaunchTool
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: DS.Space.md) {
            quickLaunchIcon(name: tool.icon, size: 17)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name.isEmpty ? "Untitled" : tool.name)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: DS.Space.sm)

            Button("Edit", action: onEdit)
                .buttonStyle(.link)
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove launcher")
            }
            Toggle("", isOn: Binding(get: { tool.enabled }, set: onToggle))
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        switch tool.role {
        case .server:   return "Per-project Run Server command"
        case .terminal: return "Default login shell"
        case .command:  return tool.command.isEmpty ? "No command set" : tool.command
        }
    }
}

private struct LaunchToolEditor: View {
    @State private var draft: LaunchTool
    let isNew: Bool
    let onSave: (LaunchTool) -> Void
    let onCancel: () -> Void

    private let iconPresets = [
        "brand:claude", "brand:codex", "terminal", "play.circle", "sparkles",
        "wand.and.stars", "bolt.fill", "hammer.fill", "cpu", "ant.fill",
        "globe", "command", "chevron.left.forwardslash.chevron.right"
    ]

    private let iconColumns = [GridItem(.adaptive(minimum: 34), spacing: DS.Space.sm)]

    init(tool: LaunchTool, isNew: Bool, onSave: @escaping (LaunchTool) -> Void, onCancel: @escaping () -> Void) {
        self._draft = State(initialValue: tool)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text(isNew ? "Add Launcher" : "Edit Launcher")
                .font(.headline)

            VStack(alignment: .leading, spacing: DS.Space.md) {
                labeledField("Name") {
                    TextField("e.g. Aider", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }

                if draft.role == .command {
                    labeledField("Command") {
                        TextField("e.g. aider --model sonnet", text: $draft.command)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    labeledField("System-prompt flag (optional)") {
                        TextField(LaunchTool.knownPromptFlag(forCommand: draft.command) ?? "—",
                                  text: Binding(get: { draft.promptFlag ?? "" },
                                                set: { draft.promptFlag = $0.isEmpty ? nil : $0 }))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Text("Flag this CLI uses to append to its system prompt, so it learns about the `agentide` cell-bridge on launch (multi-cell workspaces only). Auto-detected for claude / qwen / continue — leave blank to use the default.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(draft.role == .server
                         ? "Runs the project's Run Server command (set per project)."
                         : "Opens your default login shell.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                labeledField("Icon") {
                    LazyVGrid(columns: iconColumns, alignment: .leading, spacing: DS.Space.sm) {
                        ForEach(iconPresets, id: \.self) { icon in
                            Button {
                                draft.icon = icon
                            } label: {
                                quickLaunchIcon(name: icon, size: 18)
                                    .frame(width: 30, height: 30)
                                    .background(
                                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                                            .fill(draft.icon == icon
                                                  ? Color.accentColor.opacity(0.25)
                                                  : Color.primary.opacity(0.05))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                                            .strokeBorder(draft.icon == icon ? Color.accentColor : .clear, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save") { onSave(normalized) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 420)
    }

    @ViewBuilder
    private func labeledField(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var normalized: LaunchTool {
        var t = draft
        t.name = t.name.trimmingCharacters(in: .whitespaces)
        t.command = t.command.trimmingCharacters(in: .whitespaces)
        return t
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (draft.role != .command || !draft.command.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}
