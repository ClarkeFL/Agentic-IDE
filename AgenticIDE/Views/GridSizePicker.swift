import SwiftUI

/// Notion-style hover-to-select grid picker (≤2×4). Hovering highlights the
/// r×c block under the cursor; clicking commits that size.
struct GridSizePicker: View {
    let current: (rows: Int, cols: Int)
    let onSelect: (Int, Int) -> Void

    @State private var hover: (rows: Int, cols: Int)?

    private let dotW: CGFloat = 26
    private let dotH: CGFloat = 18

    var body: some View {
        let preview = hover ?? current
        VStack(spacing: DS.Space.sm) {
            VStack(spacing: 4) {
                ForEach(1...Workspace.maxRows, id: \.self) { r in
                    HStack(spacing: 4) {
                        ForEach(1...Workspace.maxCols, id: \.self) { c in
                            dot(row: r, col: c, preview: preview)
                        }
                    }
                }
            }
            Text("\(preview.rows) × \(preview.cols)")
                .font(DS.Font.control)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(DS.Space.md)
        .onHover { inside in if !inside { hover = nil } }
    }

    private func dot(row: Int, col: Int, preview: (rows: Int, cols: Int)) -> some View {
        let filled = row <= preview.rows && col <= preview.cols
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(filled ? Color.accentColor : Color.primary.opacity(0.12))
            .frame(width: dotW, height: dotH)
            .contentShape(Rectangle())
            .onHover { inside in if inside { hover = (row, col) } }
            .onTapGesture { onSelect(row, col) }
    }
}
