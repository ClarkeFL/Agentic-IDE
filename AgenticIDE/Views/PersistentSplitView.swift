import AppKit
import SwiftUI

/// Three-pane horizontal split view, implemented entirely in SwiftUI so it
/// is immune to the `NSSplitViewController` ↔ SwiftUI sizing quirks (where
/// the bridge would re-derive `preferredContentSize` from the splitView's
/// intrinsic size mid-drag and shrink the bridged frame).
///
/// Persistence: leading / trailing widths are stored in `UserDefaults`
/// keyed by `autosaveName`. The center pane gets the remaining width.
struct PersistentSplitView<L: View, M: View, R: View>: View {
    let autosaveName: String
    let leadingMin: CGFloat
    let leadingInitial: CGFloat
    let leadingMax: CGFloat
    let centerMin: CGFloat
    let trailingMin: CGFloat
    let trailingInitial: CGFloat
    let trailingMax: CGFloat
    let leading: () -> L
    let center: () -> M
    let trailing: () -> R

    @State private var leadingWidth: CGFloat
    @State private var trailingWidth: CGFloat
    @State private var dragLeadingStart: CGFloat?
    @State private var dragTrailingStart: CGFloat?

    init(autosaveName: String,
         leadingMin: CGFloat = 180,
         leadingInitial: CGFloat = 240,
         leadingMax: CGFloat = 420,
         centerMin: CGFloat = 360,
         trailingMin: CGFloat = 200,
         trailingInitial: CGFloat = 280,
         trailingMax: CGFloat = 600,
         @ViewBuilder leading: @escaping () -> L,
         @ViewBuilder center: @escaping () -> M,
         @ViewBuilder trailing: @escaping () -> R) {
        self.autosaveName = autosaveName
        self.leadingMin = leadingMin
        self.leadingInitial = leadingInitial
        self.leadingMax = leadingMax
        self.centerMin = centerMin
        self.trailingMin = trailingMin
        self.trailingInitial = trailingInitial
        self.trailingMax = trailingMax
        self.leading = leading
        self.center = center
        self.trailing = trailing

        let storedLeading = UserDefaults.standard.object(forKey: "\(autosaveName).leadingWidth") as? Double
        let storedTrailing = UserDefaults.standard.object(forKey: "\(autosaveName).trailingWidth") as? Double
        let lead = CGFloat(storedLeading ?? Double(leadingInitial))
        let trail = CGFloat(storedTrailing ?? Double(trailingInitial))
        self._leadingWidth = State(initialValue: max(leadingMin, min(leadingMax, lead)))
        self._trailingWidth = State(initialValue: max(trailingMin, min(trailingMax, trail)))
    }

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            // Compute clamped widths so dragging never violates mins.
            let leadingW = clamp(leadingWidth, min: leadingMin, max: leadingMax)
            let maxTrailing = max(trailingMin, total - leadingW - centerMin - DividerView.thickness * 2)
            let trailingW = min(clamp(trailingWidth, min: trailingMin, max: trailingMax), maxTrailing)
            let centerW = max(centerMin, total - leadingW - trailingW - DividerView.thickness * 2)

            HStack(spacing: 0) {
                leading()
                    .frame(width: leadingW)
                    .clipped()

                DividerView(onDrag: { delta in dragLeading(delta: delta, total: total) },
                            onDragEnd: persist)

                center()
                    .frame(width: centerW)
                    .clipped()

                DividerView(onDrag: { delta in dragTrailing(delta: delta, total: total) },
                            onDragEnd: persist)

                trailing()
                    .frame(width: trailingW)
                    .clipped()
            }
            .frame(width: total, height: geo.size.height, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drag handlers

    /// Positive delta = mouse moved right = leading should grow.
    private func dragLeading(delta: CGFloat, total: CGFloat) {
        let start = dragLeadingStart ?? leadingWidth
        if dragLeadingStart == nil { dragLeadingStart = start }
        let proposed = start + delta
        let maxAllowed = total - centerMin - trailingWidth - DividerView.thickness * 2
        leadingWidth = clamp(proposed, min: leadingMin, max: min(leadingMax, maxAllowed))
    }

    /// Positive delta = mouse moved right = trailing should shrink.
    private func dragTrailing(delta: CGFloat, total: CGFloat) {
        let start = dragTrailingStart ?? trailingWidth
        if dragTrailingStart == nil { dragTrailingStart = start }
        let proposed = start - delta
        let maxAllowed = total - centerMin - leadingWidth - DividerView.thickness * 2
        trailingWidth = clamp(proposed, min: trailingMin, max: min(trailingMax, maxAllowed))
    }

    private func persist() {
        dragLeadingStart = nil
        dragTrailingStart = nil
        UserDefaults.standard.set(Double(leadingWidth), forKey: "\(autosaveName).leadingWidth")
        UserDefaults.standard.set(Double(trailingWidth), forKey: "\(autosaveName).trailingWidth")
    }

    private func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.max(lo, Swift.min(hi, value))
    }
}

/// Thin draggable divider with an enlarged invisible hit area and a
/// resize-cursor on hover. Reports drag deltas to the parent so the
/// parent owns the width state and the clamping rules.
private struct DividerView: View {
    static let thickness: CGFloat = 1
    static let hitArea: CGFloat = 7
    let onDrag: (CGFloat) -> Void
    let onDragEnd: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: Self.thickness)
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: Self.hitArea)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle().inset(by: -3))
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in onDrag(value.translation.width) }
                .onEnded { _ in onDragEnd() }
        )
    }
}
