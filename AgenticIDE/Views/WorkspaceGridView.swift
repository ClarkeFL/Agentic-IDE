import AppKit
import SwiftUI

/// Renders the active workspace: a weighted split grid of cells, or — when a
/// cell is zoomed — just that cell filling the pane. Only the active workspace
/// is in the view tree; switching workspaces detaches the others' surfaces
/// (their PTY processes keep running, same as switching projects) and
/// re-attaches on return.
struct WorkspaceGridView: View {
    let project: Project
    @Bindable var session: ProjectSession
    @Bindable var workspace: Workspace

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
    }

    /// Fixed equal-sized grid. The outer stack lays groups along the layout axis;
    /// each inner stack lays that group's cells across the other axis. Cells split
    /// their stack evenly — no draggable seams. The 1px spacing lets the pane-card
    /// background show through as the inter-cell separator.
    private var grid: some View {
        let isRows = workspace.axis == .rows
        let outer = isRows ? AnyLayout(VStackLayout(spacing: 1)) : AnyLayout(HStackLayout(spacing: 1))
        let inner = isRows ? AnyLayout(HStackLayout(spacing: 1)) : AnyLayout(VStackLayout(spacing: 1))
        return outer {
            ForEach(Array(workspace.counts.enumerated()), id: \.offset) { g, count in
                inner {
                    ForEach(Array(0..<count), id: \.self) { i in
                        cellView(workspace.cellAt(group: g, index: i), isZoomed: false)
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
}
