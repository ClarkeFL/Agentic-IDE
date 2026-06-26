import Foundation
import Observation

/// Outer stacking direction of a workspace layout.
/// - `.rows`: cells are grouped into rows (top-to-bottom); `counts[i]` = cells
///   in row i (left-to-right). Lets a row span the full width.
/// - `.cols`: cells are grouped into columns (left-to-right); `counts[i]` =
///   cells in column i (top-to-bottom). Lets a column span the full height.
enum LayoutAxis: String, Codable { case rows, cols }

/// A grid shape: an outer axis plus the cell count of each group along it.
/// Equal-sized by default; the live `Workspace` carries per-seam weights so the
/// user can drag dividers to custom ratios. This 2-level model (outer groups,
/// inner cells) covers uneven layouts like "tall left column + two stacked"
/// (`.cols, [1, 2]`) or "wide top row + two below" (`.rows, [1, 2]`).
// ponytail: 2 levels only, not arbitrary BSP nesting. Every shape the picker
// offers is expressible here; add recursion only if someone needs 3-deep.
struct GridLayout: Equatable {
    var axis: LayoutAxis
    var counts: [Int]

    /// Hard ceilings. `maxCells` mirrors the old 2×4 grid; group/per-group caps
    /// keep a single preset from going pathological.
    static let maxCells = 8
    static let maxGroup = 4
    static let maxGroups = 4

    var cellCount: Int { counts.reduce(0, +) }

    var equalOuterWeights: [Double] {
        Array(repeating: 1.0 / Double(counts.count), count: counts.count)
    }
    var equalInnerWeights: [[Double]] {
        counts.map { Array(repeating: 1.0 / Double($0), count: $0) }
    }

    /// Force the shape inside the ceilings, trimming the tail until it fits.
    func clamped() -> GridLayout {
        var c = counts.map { max(1, min(Self.maxGroup, $0)) }
        if c.count > Self.maxGroups { c = Array(c.prefix(Self.maxGroups)) }
        while c.reduce(0, +) > Self.maxCells {
            if let last = c.last, last > 1 { c[c.count - 1] = last - 1 } else { c.removeLast() }
        }
        if c.isEmpty { c = [1] }
        return GridLayout(axis: axis, counts: c)
    }

    /// Smallest sensible layout that holds `n` cells (used for the auto-grown
    /// Servers workspace): one row of up to 4, then the remainder below.
    static func fit(_ n: Int) -> GridLayout {
        let count = max(1, min(maxCells, n))
        if count <= maxGroup { return GridLayout(axis: .rows, counts: [count]) }
        return GridLayout(axis: .rows, counts: [maxGroup, count - maxGroup]).clamped()
    }

    /// Preset layouts the picker offers, grouped by total cell count. Curated —
    /// each is a tidy arrangement; the user drags seams afterwards for ratios.
    static let presetsByCount: [(count: Int, layouts: [GridLayout])] = [
        (1, [GridLayout(axis: .rows, counts: [1])]),
        (2, [GridLayout(axis: .cols, counts: [1, 1]),
             GridLayout(axis: .rows, counts: [1, 1])]),
        (3, [GridLayout(axis: .cols, counts: [1, 2]),
             GridLayout(axis: .rows, counts: [1, 2]),
             GridLayout(axis: .cols, counts: [2, 1]),
             GridLayout(axis: .rows, counts: [2, 1]),
             GridLayout(axis: .cols, counts: [1, 1, 1]),
             GridLayout(axis: .rows, counts: [1, 1, 1])]),
        (4, [GridLayout(axis: .rows, counts: [2, 2]),
             GridLayout(axis: .cols, counts: [1, 3]),
             GridLayout(axis: .rows, counts: [1, 3]),
             GridLayout(axis: .cols, counts: [3, 1]),
             GridLayout(axis: .cols, counts: [1, 1, 1, 1]),
             GridLayout(axis: .rows, counts: [1, 1, 1, 1])]),
        (5, [GridLayout(axis: .cols, counts: [1, 2, 2]),
             GridLayout(axis: .rows, counts: [1, 2, 2]),
             GridLayout(axis: .cols, counts: [2, 3]),
             GridLayout(axis: .rows, counts: [2, 3])]),
        (6, [GridLayout(axis: .rows, counts: [3, 3]),
             GridLayout(axis: .cols, counts: [3, 3]),
             GridLayout(axis: .rows, counts: [2, 2, 2]),
             GridLayout(axis: .cols, counts: [2, 2, 2])]),
        (7, [GridLayout(axis: .rows, counts: [3, 4]),
             GridLayout(axis: .cols, counts: [1, 3, 3]),
             GridLayout(axis: .rows, counts: [1, 3, 3])]),
        (8, [GridLayout(axis: .rows, counts: [4, 4]),
             GridLayout(axis: .cols, counts: [4, 4]),
             GridLayout(axis: .rows, counts: [2, 2, 2, 2])]),
    ]
}

/// A grid of terminal cells inside a project. A project owns several of these;
/// each is an independent layout (≤8 cells) the user switches between from the
/// sidebar. Cells are stored flat in reading order; `counts` slices that array
/// into the rows/columns described by `axis`. `outerWeights` size the groups
/// along the axis and `innerWeights[g]` size the cells within group g — both
/// mutated in place when the user drags a divider.
@Observable
final class Workspace: Identifiable {
    /// Hard ceiling on cell count. Mirrors `GridLayout.maxCells`.
    static let maxCells = GridLayout.maxCells

    let id: UUID
    var name: String
    private(set) var axis: LayoutAxis
    private(set) var counts: [Int]
    /// Fractions (sum 1) sizing each group along the axis. `var` so the grid's
    /// draggable seams can rebalance them.
    var outerWeights: [Double]
    /// Per-group fractions (each sub-array sums to 1) sizing the cells inside.
    var innerWeights: [[Double]]
    private(set) var cells: [WorkspaceCell]

    /// When set, only this cell is shown, filling the workspace. nil = full grid.
    var zoomedCellId: UUID?
    /// The cell the user last focused — drives the keyboard zoom shortcut.
    var focusedCellId: UUID?

    var layout: GridLayout { GridLayout(axis: axis, counts: counts) }
    var cellCount: Int { cells.count }

    /// Fresh single-cell workspace.
    convenience init(name: String) {
        self.init(id: UUID(), name: name,
                  layout: GridLayout(axis: .rows, counts: [1]),
                  outerWeights: nil, innerWeights: nil,
                  cells: [WorkspaceCell()])
    }

    /// Full init used by restore. Pads/truncates `cells` to the layout's cell
    /// count and validates the weights, so a malformed snapshot can never desync
    /// the grid from its cell array.
    init(id: UUID, name: String, layout rawLayout: GridLayout,
         outerWeights: [Double]?, innerWeights: [[Double]]?, cells rawCells: [WorkspaceCell]) {
        self.id = id
        self.name = name
        let layout = rawLayout.clamped()
        self.axis = layout.axis
        self.counts = layout.counts
        var fixed = rawCells
        while fixed.count < layout.cellCount { fixed.append(WorkspaceCell()) }
        if fixed.count > layout.cellCount { fixed = Array(fixed.prefix(layout.cellCount)) }
        self.cells = fixed
        self.outerWeights = Self.normalized(outerWeights, count: layout.counts.count)
            ?? layout.equalOuterWeights
        self.innerWeights = Self.normalizedInner(innerWeights, counts: layout.counts)
            ?? layout.equalInnerWeights
    }

    /// 0-based flat index of the first cell in group `g`.
    func groupOffset(_ g: Int) -> Int {
        counts.prefix(g).reduce(0, +)
    }

    /// The cell at (group, index-within-group), mapped onto the flat array.
    func cellAt(group g: Int, index i: Int) -> WorkspaceCell {
        cells[groupOffset(g) + i]
    }

    /// All cells currently running a process.
    var runningCells: [WorkspaceCell] {
        cells.filter { $0.terminal != nil }
    }

    /// Apply a new layout shape, preserving cells by reading order (dropping the
    /// tail that no longer fits) and resetting seam weights to equal. Returns the
    /// dropped cells so the caller can tear down their terminals.
    @discardableResult
    func apply(_ rawLayout: GridLayout) -> [WorkspaceCell] {
        let next = rawLayout.clamped()
        guard next != layout else { return [] }
        let newCount = next.cellCount

        var dropped: [WorkspaceCell] = []
        if cells.count > newCount {
            dropped = Array(cells[newCount...])
            cells = Array(cells.prefix(newCount))
        } else {
            while cells.count < newCount { cells.append(WorkspaceCell()) }
        }

        axis = next.axis
        counts = next.counts
        outerWeights = next.equalOuterWeights
        innerWeights = next.equalInnerWeights
        if let z = zoomedCellId, !cells.contains(where: { $0.id == z }) { zoomedCellId = nil }
        if let f = focusedCellId, !cells.contains(where: { $0.id == f }) { focusedCellId = nil }
        return dropped
    }

    /// Compact human/agent-facing description, e.g. "2×2", "1+2 rows".
    var layoutDescription: String {
        if let first = counts.first, counts.allSatisfy({ $0 == first }) {
            return axis == .rows ? "\(counts.count)×\(first)" : "\(first)×\(counts.count)"
        }
        let joined = counts.map(String.init).joined(separator: "+")
        return "\(joined) \(axis.rawValue)"
    }

    // MARK: - Weight validation

    private static func normalized(_ w: [Double]?, count: Int) -> [Double]? {
        guard let w, w.count == count, w.allSatisfy({ $0 > 0 }) else { return nil }
        let s = w.reduce(0, +)
        return s > 0 ? w.map { $0 / s } : nil
    }

    private static func normalizedInner(_ w: [[Double]]?, counts: [Int]) -> [[Double]]? {
        guard let w, w.count == counts.count else { return nil }
        var out: [[Double]] = []
        for (g, sub) in w.enumerated() {
            guard let v = normalized(sub, count: counts[g]) else { return nil }
            out.append(v)
        }
        return out
    }
}
