import SwiftUI

/// Compact pane title — the sidebar's "Projects" heading. Matches the visual
/// treatment of the inspector mode-toggle so "Projects" and "Files / Changes"
/// read at the same hierarchy level.
struct PaneTitle: View {
    let label: String
    let count: Int?

    init(_ label: String, count: Int? = nil) {
        self.label = label
        self.count = count
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.sm) {
            Text(label)
                .font(DS.Font.control)
                .foregroundStyle(.primary)
            if let count, count > 0 {
                Text("\(count)")
                    .font(DS.Font.badge)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Space.xs + 1)
                    .frame(height: DS.Control.micro)
                    .background(Color.primary.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }
}
