import SwiftUI

/// Renders the active workspace: an equal-split grid of cells, or — when a cell
/// is zoomed — just that cell filling the pane. Only the active workspace is in
/// the view tree; switching workspaces detaches the others' surfaces (their PTY
/// processes keep running, same as switching projects) and re-attaches on
/// return.
struct WorkspaceGridView: View {
    let project: Project
    @Bindable var session: ProjectSession
    @Bindable var workspace: Workspace

    private let gap: CGFloat = DS.Space.xs

    var body: some View {
        Group {
            if let zid = workspace.zoomedCellId,
               let zoomed = workspace.cells.first(where: { $0.id == zid }) {
                cellView(zoomed, isZoomed: true)
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Flush on the leading (divider) side; breathing room on the window
        // edges (top gap from header, bottom + trailing window border).
        .padding(EdgeInsets(top: gap, leading: 0, bottom: DS.Space.md, trailing: DS.Space.md))
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var grid: some View {
        VStack(spacing: gap) {
            ForEach(rowSlices, id: \.id) { row in
                HStack(spacing: gap) {
                    ForEach(row.cells) { cell in
                        cellView(cell, isZoomed: false)
                    }
                }
            }
        }
    }

    private func cellView(_ cell: WorkspaceCell, isZoomed: Bool) -> some View {
        WorkspaceCellView(project: project,
                          session: session,
                          workspace: workspace,
                          cell: cell,
                          isActive: true,
                          isZoomed: isZoomed)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Slice the row-major cells array into rows, keyed by the first cell's id
    /// so SwiftUI diffs by identity (avoids the mutable-count `ForEach(0..<n)`
    /// pitfall when the grid is resized).
    private var rowSlices: [(id: UUID, cells: [WorkspaceCell])] {
        var out: [(UUID, [WorkspaceCell])] = []
        let cols = workspace.cols
        for r in 0..<workspace.rows {
            let start = r * cols
            let slice = Array(workspace.cells[start..<min(start + cols, workspace.cells.count)])
            out.append((slice.first?.id ?? UUID(), slice))
        }
        return out
    }
}
