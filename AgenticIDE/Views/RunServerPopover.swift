import SwiftUI

/// Inline editor for an empty Run Server command, anchored to the button.
struct RunServerPopover: View {
    let initialCommand: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String

    init(initialCommand: String,
         onSave: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.initialCommand = initialCommand
        self.onSave = onSave
        self.onCancel = onCancel
        self._draft = State(initialValue: initialCommand)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set the Run Server command for this project")
                .font(.headline)
            Text("Runs in the project root via your login shell.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. npm run dev", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}
