import SwiftUI

/// Palette of preset layouts grouped by cell count. Each thumbnail is a live
/// mini-map of the layout's shape (including uneven ones like a tall left
/// column or a wide top row); clicking commits it. Replaces the old Notion-style
/// rows×cols drag picker now that layouts aren't a plain rectangle.
struct GridLayoutPicker: View {
    /// The current layout, highlighted in the palette. nil when creating a new
    /// workspace (nothing pre-selected).
    var current: GridLayout?
    let onSelect: (GridLayout) -> Void

    /// Three thumbnails per row keeps each count's options compact.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: DS.Space.sm), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                ForEach(GridLayout.presetsByCount, id: \.count) { group in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("\(group.count) cell\(group.count == 1 ? "" : "s")")
                            .font(DS.Font.control)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, spacing: DS.Space.sm) {
                            ForEach(Array(group.layouts.enumerated()), id: \.offset) { _, layout in
                                thumbnail(layout)
                            }
                        }
                    }
                }
            }
            .padding(DS.Space.md)
        }
        .frame(width: 360, height: 460)
    }

    private func thumbnail(_ layout: GridLayout) -> some View {
        let selected = layout == current
        return Button { onSelect(layout) } label: {
            LayoutGlyph(layout: layout, square: 10, gap: 3) { _, _ in
                selected ? Color.accentColor : Color.primary.opacity(0.3)
            }
            .frame(width: 52, height: 52)
            .padding(DS.Space.xs)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(Color.accentColor.opacity(selected ? 0.12 : 0.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1),
                                  lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(layout.cellCount == 1 ? "Single cell"
              : "\(layout.cellCount) cells · \(layout.counts.map(String.init).joined(separator: "+")) \(layout.axis.rawValue)")
    }
}
