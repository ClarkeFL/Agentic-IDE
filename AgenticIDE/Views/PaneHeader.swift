import SwiftUI

/// Top strip that runs across every column of the main window — sidebar,
/// workspace, inspector. Locks all three to the same height (`DS.Control.header`)
/// and the same trailing `Divider()`, so the three columns visually align as
/// one toolbar instead of three independent panes.
///
/// Without this, each column was free to invent its own header height: the
/// tab bar (workspace) was ~34pt because of inner padding, the inspector was
/// 30pt by an explicit `.frame(height:)`, and the sidebar didn't have a
/// header at all — its content just collided with the window titlebar. The
/// shared component is the only way to keep them in sync.
struct PaneHeader<Content: View>: View {
    let content: Content
    let leadingPadding: CGFloat
    let trailingPadding: CGFloat

    init(leadingPadding: CGFloat = DS.Space.md,
         trailingPadding: CGFloat = DS.Space.md,
         @ViewBuilder content: () -> Content) {
        self.content = content()
        self.leadingPadding = leadingPadding
        self.trailingPadding = trailingPadding
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, leadingPadding)
                .padding(.trailing, trailingPadding)
                .frame(height: DS.Control.header)
            Divider()
        }
        // Solid (not translucent) so content scrolling underneath doesn't blur
        // through the header as a faint shaded band. Matches the editor header.
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// Compact pane title — used as the default content of `PaneHeader` for the
/// sidebar. Matches the visual treatment of the inspector mode-toggle so
/// "Projects" and "Files / Changes" read at the same hierarchy level.
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
