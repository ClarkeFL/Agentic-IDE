import AppKit
import SwiftUI

/// Settings → Shortcuts. Lists every rebindable command; click a shortcut and
/// press a new combo to rebind it. Overrides are persisted in `KeybindingStore`
/// and the menus read from there.
struct KeybindingsSettingsView: View {
    @Environment(KeybindingStore.self) private var store
    @State private var recording: ShortcutAction?

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    let binding = store.binding(for: action)
                    ShortcutRow(
                        title: action.title,
                        binding: binding,
                        isRecording: recording == action,
                        isOverridden: store.isOverridden(action),
                        conflict: store.conflict(for: action, binding: binding)?.title,
                        onStart: { recording = action },
                        onRecord: { kb in store.set(kb, for: action); recording = nil },
                        onCancel: { recording = nil },
                        onReset: { store.reset(action) })
                }
            } header: {
                Label("Keyboard Shortcuts", systemImage: "command")
            } footer: {
                Text("Click a shortcut and press the new keys (must include ⌘ or ⌃). Press Escape to cancel. Conflicts are flagged but allowed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button("Reset All to Defaults") { store.resetAll() }
            }
        }
        .formStyle(.grouped)
        .padding(.top, DS.Space.md)
    }
}

private struct ShortcutRow: View {
    let title: String
    let binding: Keybinding
    let isRecording: Bool
    let isOverridden: Bool
    let conflict: String?
    let onStart: () -> Void
    let onRecord: (Keybinding) -> Void
    let onCancel: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                if let conflict {
                    Text("Also used by \(conflict)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: DS.Space.sm)
            if isOverridden && !isRecording {
                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset to default")
            }
            RecorderButton(display: binding.display,
                           isRecording: isRecording,
                           onStart: onStart,
                           onRecord: onRecord,
                           onCancel: onCancel)
        }
        .padding(.vertical, 2)
    }
}

private struct RecorderButton: View {
    let display: String
    let isRecording: Bool
    let onStart: () -> Void
    let onRecord: (Keybinding) -> Void
    let onCancel: () -> Void

    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording { onCancel() } else { onStart() }
        } label: {
            Text(isRecording ? "Press keys…" : display)
                .font(.body.monospaced())
                .frame(minWidth: 96)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(isRecording ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .strokeBorder(isRecording ? Color.accentColor : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onChange(of: isRecording) { _, recording in
            if recording { start() } else { stop() }
        }
        .onDisappear { stop() }
    }

    private func start() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stop()
                DispatchQueue.main.async { onCancel() }
                return nil
            }
            if let kb = Keybinding(event: event) {
                stop()
                DispatchQueue.main.async { onRecord(kb) }
            }
            return nil // consume keys while recording
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}
