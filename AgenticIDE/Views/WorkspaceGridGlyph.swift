import SwiftUI

/// A miniature live map of a workspace's grid: one tiny square per cell, laid
/// out in the workspace's actual rows × cols, each square coloured by its
/// cell's terminal status (grey = empty, muted = idle, blue = working,
/// green = done, red = failed). Replaces the old "1×1" dims text + status dots
/// — it conveys both the layout and per-cell state at a glance.
struct WorkspaceGridGlyph: View {
    @Bindable var workspace: Workspace
    var square: CGFloat = 5
    var gap: CGFloat = 1.5
    var corner: CGFloat = 1.2

    var body: some View {
        VStack(spacing: gap) {
            ForEach(rowChunks, id: \.index) { chunk in
                HStack(spacing: gap) {
                    ForEach(chunk.cells) { cell in
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(color(for: cell))
                            .frame(width: square, height: square)
                    }
                }
            }
        }
    }

    private struct RowChunk { let index: Int; let cells: [WorkspaceCell] }

    private var rowChunks: [RowChunk] {
        let cols = workspace.cols
        var out: [RowChunk] = []
        for r in 0..<workspace.rows {
            let start = r * cols
            let end = min(start + cols, workspace.cells.count)
            guard start < end else { continue }
            out.append(RowChunk(index: r, cells: Array(workspace.cells[start..<end])))
        }
        return out
    }

    private func color(for cell: WorkspaceCell) -> Color {
        guard let tab = cell.terminal else { return Color.primary.opacity(0.16) }
        if let info = TerminalStatusBadge.info(for: tab.status) { return info.color }
        return Color.secondary.opacity(0.55)
    }
}
