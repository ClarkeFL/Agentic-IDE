import SwiftUI

/// A miniature map of a `GridLayout`: one tiny rounded rect per cell, laid out
/// in the layout's actual shape so a spanning row/column reads as a wider/taller
/// tile. `fill` colours each cell by (group, index-within-group).
struct LayoutGlyph: View {
    let layout: GridLayout
    var square: CGFloat = 5
    var gap: CGFloat = 1.5
    var corner: CGFloat = 1.2
    let fill: (Int, Int) -> Color

    var body: some View {
        let isRows = layout.axis == .rows
        let maxCount = max(1, layout.counts.max() ?? 1)
        // The long-axis length every group spans, so a 1-cell group fills it.
        let span = CGFloat(maxCount) * square + CGFloat(maxCount - 1) * gap
        outerStack(isRows) {
            ForEach(Array(layout.counts.enumerated()), id: \.offset) { g, c in
                innerStack(isRows) {
                    ForEach(0..<c, id: \.self) { i in
                        let len = (span - gap * CGFloat(c - 1)) / CGFloat(c)
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(fill(g, i))
                            .frame(width: isRows ? len : square,
                                   height: isRows ? square : len)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func outerStack<C: View>(_ isRows: Bool, @ViewBuilder _ content: () -> C) -> some View {
        if isRows { VStack(spacing: gap, content: content) }
        else { HStack(spacing: gap, content: content) }
    }

    @ViewBuilder
    private func innerStack<C: View>(_ isRows: Bool, @ViewBuilder _ content: () -> C) -> some View {
        if isRows { HStack(spacing: gap, content: content) }
        else { VStack(spacing: gap, content: content) }
    }
}

/// A live `LayoutGlyph` for a workspace: each cell coloured by its terminal
/// status (grey = empty, muted = idle, blue = working, green = done, red =
/// failed). Conveys both the layout and per-cell state at a glance.
struct WorkspaceGridGlyph: View {
    @Bindable var workspace: Workspace
    var square: CGFloat = 5
    var gap: CGFloat = 1.5
    var corner: CGFloat = 1.2

    var body: some View {
        LayoutGlyph(layout: workspace.layout, square: square, gap: gap, corner: corner) { g, i in
            color(for: workspace.cellAt(group: g, index: i))
        }
    }

    private func color(for cell: WorkspaceCell) -> Color {
        guard let tab = cell.terminal else { return Color.primary.opacity(0.16) }
        if let info = TerminalStatusBadge.info(for: tab.status) { return info.color }
        return Color.secondary.opacity(0.55)
    }
}
