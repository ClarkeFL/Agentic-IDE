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

    /// Two nested weighted splits: the outer one stacks the groups along the
    /// layout axis; each inner one lays the group's cells across the other axis.
    /// Dividers between siblings are draggable and rebalance the shared weights,
    /// which persist via `markDirty()` on drag end.
    private var grid: some View {
        let isRows = workspace.axis == .rows
        return WeightedSplit(orientation: isRows ? .vertical : .horizontal,
                             weights: $workspace.outerWeights,
                             onCommit: session.markDirty) { g in
            WeightedSplit(orientation: isRows ? .horizontal : .vertical,
                          weights: $workspace.innerWeights[g],
                          onCommit: session.markDirty) { i in
                cellView(workspace.cellAt(group: g, index: i), isZoomed: false)
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

/// Lays `weights.count` children along `orientation`, each sized to its weight
/// fraction of the available length, with a draggable 1px divider between
/// adjacent children. Dragging a divider transfers weight between the two panes
/// it sits between (clamped so neither drops below `minFraction`).
struct WeightedSplit<Content: View>: View {
    let orientation: Axis
    @Binding var weights: [Double]
    var minFraction: CGFloat = 0.1
    let onCommit: () -> Void
    @ViewBuilder let content: (Int) -> Content

    /// Snapshot of the weights when a divider drag begins, so each move is
    /// computed from a stable baseline rather than accumulating rounding.
    @State private var dragStart: [Double]?

    var body: some View {
        GeometryReader { geo in
            let horizontal = orientation == .horizontal
            let axisLength = horizontal ? geo.size.width : geo.size.height
            // The 1px dividers consume space too; size panes from what's left so
            // they sum to the container instead of overflowing by (n-1)px.
            let usable = max(0, axisLength - CGFloat(weights.count - 1))
            let fractions = paneFractions
            let layout = horizontal
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(weights.indices, id: \.self) { i in
                    let length = max(0, fractions[i] * usable)
                    sizedPane(content(i), horizontal: horizontal, length: length)
                    if i < weights.count - 1 {
                        divider(after: i, total: usable, horizontal: horizontal)
                    }
                }
            }
        }
    }

    /// Fix the along-axis size to `length`; let the cross axis fill.
    @ViewBuilder
    private func sizedPane<V: View>(_ view: V, horizontal: Bool, length: CGFloat) -> some View {
        if horizontal {
            view.frame(width: length).frame(maxHeight: .infinity)
        } else {
            view.frame(height: length).frame(maxWidth: .infinity)
        }
    }

    /// Weights renormalised to sum to 1 (defensive — they should already).
    private var paneFractions: [Double] {
        let sum = weights.reduce(0, +)
        guard sum > 0 else {
            return Array(repeating: 1.0 / Double(max(1, weights.count)), count: weights.count)
        }
        return weights.map { $0 / sum }
    }

    private func divider(after i: Int, total: CGFloat, horizontal: Bool) -> some View {
        Divider()
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: horizontal ? 10 : nil, height: horizontal ? nil : 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                        else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = dragStart ?? paneFractions
                                if dragStart == nil { dragStart = base }
                                let pts = horizontal ? value.translation.width : value.translation.height
                                rebalance(divider: i, delta: pts / max(total, 1), from: base)
                            }
                            .onEnded { _ in
                                dragStart = nil
                                onCommit()
                            }
                    )
            )
    }

    /// Shift `delta` (as a fraction of total length) from pane i+1 to pane i,
    /// keeping their combined size — and the overall sum — constant.
    private func rebalance(divider i: Int, delta: CGFloat, from base: [Double]) {
        guard base.indices.contains(i), base.indices.contains(i + 1) else { return }
        let combined = base[i] + base[i + 1]
        let lo = Double(minFraction)
        let hi = combined - Double(minFraction)
        guard hi > lo else { return }
        let newI = min(max(base[i] + Double(delta), lo), hi)
        var next = base
        next[i] = newI
        next[i + 1] = combined - newI
        weights = next
    }
}
