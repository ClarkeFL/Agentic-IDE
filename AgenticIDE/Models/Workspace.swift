import Foundation
import Observation

/// A grid of terminal cells inside a project. A project owns several of these;
/// each is an independent layout (≤2 rows × 4 cols) the user switches between
/// from the sidebar. Cells are stored row-major: `cells[row * cols + col]`.
@Observable
final class Workspace: Identifiable {
    /// Hard ceiling on the grid. Mirrors the UI's 2×4 picker.
    static let maxRows = 2
    static let maxCols = 4

    let id: UUID
    var name: String
    private(set) var rows: Int
    private(set) var cols: Int
    private(set) var cells: [WorkspaceCell]

    /// When set, only this cell is shown, filling the workspace. nil = full grid.
    var zoomedCellId: UUID?
    /// The cell the user last focused — drives the keyboard zoom shortcut.
    var focusedCellId: UUID?

    /// Fresh single-cell workspace.
    convenience init(name: String) {
        self.init(id: UUID(), name: name, rows: 1, cols: 1, cells: [WorkspaceCell()])
    }

    /// Full init used by restore. Pads/truncates `cells` to `rows * cols` so a
    /// malformed snapshot can never desync the grid from its cell array.
    init(id: UUID, name: String, rows: Int, cols: Int, cells: [WorkspaceCell]) {
        self.id = id
        self.name = name
        let r = max(1, min(Self.maxRows, rows))
        let c = max(1, min(Self.maxCols, cols))
        self.rows = r
        self.cols = c
        var fixed = cells
        while fixed.count < r * c { fixed.append(WorkspaceCell()) }
        if fixed.count > r * c { fixed = Array(fixed.prefix(r * c)) }
        self.cells = fixed
    }

    func cell(row: Int, col: Int) -> WorkspaceCell {
        cells[row * cols + col]
    }

    /// All cells currently running a process.
    var runningCells: [WorkspaceCell] {
        cells.filter { $0.terminal != nil }
    }

    /// Resize the grid, preserving any cell that still fits at the same
    /// (row, col). Returns the cells that fell outside the new bounds so the
    /// caller can tear down their terminals.
    @discardableResult
    func resize(rows newRows: Int, cols newCols: Int) -> [WorkspaceCell] {
        let r = max(1, min(Self.maxRows, newRows))
        let c = max(1, min(Self.maxCols, newCols))
        guard r != rows || c != cols else { return [] }

        var next: [WorkspaceCell] = []
        next.reserveCapacity(r * c)
        for nr in 0..<r {
            for nc in 0..<c {
                if nr < rows && nc < cols {
                    next.append(cells[nr * cols + nc])
                } else {
                    next.append(WorkspaceCell())
                }
            }
        }

        var dropped: [WorkspaceCell] = []
        for or in 0..<rows {
            for oc in 0..<cols {
                if or >= r || oc >= c {
                    dropped.append(cells[or * cols + oc])
                }
            }
        }

        rows = r
        cols = c
        cells = next
        if let z = zoomedCellId, !next.contains(where: { $0.id == z }) {
            zoomedCellId = nil
        }
        if let f = focusedCellId, !next.contains(where: { $0.id == f }) {
            focusedCellId = nil
        }
        return dropped
    }
}
