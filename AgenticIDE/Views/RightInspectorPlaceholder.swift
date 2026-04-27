import SwiftUI

/// Placeholder for the right inspector. Plan C will fill in the file tree
/// and git diff view.
struct RightInspectorPlaceholder: View {
    let project: Project?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FILES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let project {
                Text(project.path.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer()
            Text("File tree + git diff coming soon.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
