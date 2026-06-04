import AppKit
import SwiftUI

/// Four-pane horizontal split view. SwiftUI-only — no `NSSplitViewController`
/// — so the bridge can't re-derive `preferredContentSize` mid-drag and shrink
/// the bridged frame. Panes 1, 2 and 4 have persisted widths; pane 3 (the
/// editor) absorbs whatever's left.
///
/// Persistence: pane widths are stored in `UserDefaults` keyed by
/// `autosaveName` (`<name>.pane1Width`, `<name>.pane2Width`,
/// `<name>.pane4Width`).
struct PersistentSplitView<P1: View, P2: View, P3: View, P4: View>: View {
    let autosaveName: String

    let pane1Min: CGFloat
    let pane1Initial: CGFloat
    let pane1Max: CGFloat

    let pane2Min: CGFloat
    let pane2Initial: CGFloat
    let pane2Max: CGFloat

    let pane3Min: CGFloat
    /// When true, pane 3 and its preceding divider are removed from the
    /// layout and pane 4 absorbs the freed width. Used by `MainWindow` to
    /// auto-hide the editor pane when no files are open.
    let pane3Collapsed: Bool

    let pane4Min: CGFloat
    let pane4Initial: CGFloat
    let pane4Max: CGFloat

    let pane1: () -> P1
    let pane2: () -> P2
    let pane3: () -> P3
    let pane4: () -> P4

    @State private var pane1Width: CGFloat
    @State private var pane2Width: CGFloat
    @State private var pane4Width: CGFloat
    @State private var dragStart1: CGFloat?
    @State private var dragStart2: CGFloat?
    @State private var dragStart4: CGFloat?
    @State private var isDragging: Bool = false

    init(autosaveName: String,
         pane1Min: CGFloat = 160,
         pane1Initial: CGFloat = 200,
         pane1Max: CGFloat = 360,
         pane2Min: CGFloat = 180,
         pane2Initial: CGFloat = 240,
         pane2Max: CGFloat = 480,
         pane3Min: CGFloat = 320,
         pane3Collapsed: Bool = false,
         pane4Min: CGFloat = 280,
         pane4Initial: CGFloat = 420,
         pane4Max: CGFloat = 900,
         @ViewBuilder pane1: @escaping () -> P1,
         @ViewBuilder pane2: @escaping () -> P2,
         @ViewBuilder pane3: @escaping () -> P3,
         @ViewBuilder pane4: @escaping () -> P4) {
        self.autosaveName = autosaveName
        self.pane1Min = pane1Min
        self.pane1Initial = pane1Initial
        self.pane1Max = pane1Max
        self.pane2Min = pane2Min
        self.pane2Initial = pane2Initial
        self.pane2Max = pane2Max
        self.pane3Min = pane3Min
        self.pane3Collapsed = pane3Collapsed
        self.pane4Min = pane4Min
        self.pane4Initial = pane4Initial
        self.pane4Max = pane4Max
        self.pane1 = pane1
        self.pane2 = pane2
        self.pane3 = pane3
        self.pane4 = pane4

        let s1 = UserDefaults.standard.object(forKey: "\(autosaveName).pane1Width") as? Double
        let s2 = UserDefaults.standard.object(forKey: "\(autosaveName).pane2Width") as? Double
        let s4 = UserDefaults.standard.object(forKey: "\(autosaveName).pane4Width") as? Double
        let w1 = CGFloat(s1 ?? Double(pane1Initial))
        let w2 = CGFloat(s2 ?? Double(pane2Initial))
        let w4 = CGFloat(s4 ?? Double(pane4Initial))
        self._pane1Width = State(initialValue: max(pane1Min, min(pane1Max, w1)))
        self._pane2Width = State(initialValue: max(pane2Min, min(pane2Max, w2)))
        self._pane4Width = State(initialValue: max(pane4Min, min(pane4Max, w4)))
    }

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            // Each DividerView's ZStack stretches to its widest child —
            // the 9pt invisible hit-target — so it reserves 9pt of layout
            // space, NOT the 1pt visible separator. Budgeting 1pt here was
            // the source of pane 4 overflowing the window's right edge by
            // 24pt (3 dividers × 8pt of unaccounted-for space) and
            // clipping the speaker button + Claude's banner text.
            //
            // When pane 3 is collapsed we drop its preceding divider too,
            // so only two dividers exist in the layout.
            let dividerCount: CGFloat = pane3Collapsed ? 2 : 3
            let dividers = DividerView.layoutWidth * dividerCount
            let widths = computeWidths(total: total, dividers: dividers)
            let w1 = widths.p1
            let w2 = widths.p2
            let w3 = widths.p3
            let w4 = widths.p4

            HStack(spacing: 0) {
                pane1()
                    .frame(width: w1)
                    .clipped()

                DividerView(onDrag: { delta in dragPane1(delta: delta, total: total) },
                            onDragStart: { isDragging = true },
                            onDragEnd: { persist(); isDragging = false })

                pane2()
                    .frame(width: w2)
                    .clipped()

                if !pane3Collapsed {
                    DividerView(onDrag: { delta in dragPane2(delta: delta, total: total) },
                                onDragStart: { isDragging = true },
                                onDragEnd: { persist(); isDragging = false })

                    pane3()
                        .frame(width: w3)
                        .clipped()
                }

                DividerView(onDrag: { delta in dragPane4(delta: delta, total: total) },
                            onDragStart: { isDragging = true },
                            onDragEnd: { persist(); isDragging = false })

                pane4()
                    .frame(width: w4)
                    .clipped()
            }
            .transaction { t in if isDragging { t.animation = nil } }
            .frame(width: total, height: geo.size.height, alignment: .leading)
            // Belt-and-braces clip — even if the maths above had a
            // miscalculation, content can never paint outside the
            // GeometryReader's reported bounds.
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Resolve the four pane widths so they sum exactly to `total - dividers`,
    /// no matter how narrow the window is. Algorithm:
    ///   1. Start each pane at its persisted-and-clamped width.
    ///   2. Pane 3 (editor) takes whatever's left.
    ///   3. If the four widths overflow `total`, shrink in priority order
    ///      (pane 4 → pane 2 → pane 1 → pane 3) until they fit.
    ///   4. If we still overflow after every pane is at zero, scale the
    ///      result down proportionally as a last-ditch defence.
    /// Pane mins are honoured during the squeeze; only after every other
    /// pane has bottomed out does pane 3 itself dip below its min. The old
    /// layout produced an overflow on windows whose mins summed past the
    /// window width, clipping content (visibly the terminal pane).
    private func computeWidths(total: CGFloat, dividers: CGFloat) -> (p1: CGFloat, p2: CGFloat, p3: CGFloat, p4: CGFloat) {
        let usable = max(0, total - dividers)
        var w1 = clamp(pane1Width, min: pane1Min, max: pane1Max)
        var w2 = clamp(pane2Width, min: pane2Min, max: pane2Max)
        var w4 = clamp(pane4Width, min: pane4Min, max: pane4Max)
        var w3 = max(pane3Min, usable - w1 - w2 - w4)

        // Collapsed mode: pane 3 is zero-width and pane 4 swallows the
        // freed space (so the layout still fills the window). `pane4Max`
        // is intentionally bypassed — capping it here would leave a gap
        // on the right edge of wide windows; the collapse is meant to be
        // edge-to-edge.
        if pane3Collapsed {
            w3 = 0
            w4 = max(pane4Min, usable - w1 - w2)
            return (w1, w2, w3, w4)
        }

        var overflow = (w1 + w2 + w3 + w4) - usable
        if overflow > 0 {
            // Shrink pane 4 first, down to its min.
            let take4 = min(max(0, w4 - pane4Min), overflow)
            w4 -= take4
            overflow -= take4

            // Then pane 2.
            if overflow > 0 {
                let take2 = min(max(0, w2 - pane2Min), overflow)
                w2 -= take2
                overflow -= take2
            }

            // Then pane 1.
            if overflow > 0 {
                let take1 = min(max(0, w1 - pane1Min), overflow)
                w1 -= take1
                overflow -= take1
            }

            // Then pane 3 (editor) — let it dip below its own min.
            if overflow > 0 {
                let take3 = min(max(0, w3), overflow)
                w3 -= take3
                overflow -= take3
            }
        }

        // Sanity belt-and-braces: if we somehow still overflow (truly tiny
        // window), scale every pane down proportionally so the sum can
        // never exceed `usable`. Prevents content rendering off the right
        // edge of the window.
        let sum = w1 + w2 + w3 + w4
        if sum > usable && sum > 0 {
            let scale = usable / sum
            w1 *= scale
            w2 *= scale
            w3 *= scale
            w4 *= scale
        }
        return (w1, w2, w3, w4)
    }

    // MARK: - Drag handlers

    /// Positive delta = mouse moved right = pane 1 grows. Pulled width comes
    /// from pane 3 (the elastic middle). Pane 2 stays at its persisted width
    /// unless the layout would otherwise violate pane 3's minimum.
    private func dragPane1(delta: CGFloat, total: CGFloat) {
        let start = dragStart1 ?? pane1Width
        if dragStart1 == nil { dragStart1 = start }
        let dividers = DividerView.layoutWidth * (pane3Collapsed ? 2 : 3)
        let maxAllowed = total - pane2Width - pane3Min - pane4Width - dividers
        pane1Width = clamp(start + delta, min: pane1Min, max: min(pane1Max, maxAllowed))
    }

    /// Positive delta = mouse moved right = pane 2 grows.
    private func dragPane2(delta: CGFloat, total: CGFloat) {
        let start = dragStart2 ?? pane2Width
        if dragStart2 == nil { dragStart2 = start }
        let dividers = DividerView.layoutWidth * 3
        let maxAllowed = total - pane1Width - pane3Min - pane4Width - dividers
        pane2Width = clamp(start + delta, min: pane2Min, max: min(pane2Max, maxAllowed))
    }

    /// Positive delta = mouse moved right = pane 4 shrinks.
    private func dragPane4(delta: CGFloat, total: CGFloat) {
        let start = dragStart4 ?? pane4Width
        if dragStart4 == nil { dragStart4 = start }
        let dividers = DividerView.layoutWidth * (pane3Collapsed ? 2 : 3)
        let maxAllowed = total - pane1Width - pane2Width - pane3Min - dividers
        pane4Width = clamp(start - delta, min: pane4Min, max: min(pane4Max, maxAllowed))
    }

    private func persist() {
        dragStart1 = nil
        dragStart2 = nil
        dragStart4 = nil
        UserDefaults.standard.set(Double(pane1Width), forKey: "\(autosaveName).pane1Width")
        UserDefaults.standard.set(Double(pane2Width), forKey: "\(autosaveName).pane2Width")
        UserDefaults.standard.set(Double(pane4Width), forKey: "\(autosaveName).pane4Width")
    }

    private func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.max(lo, Swift.min(hi, value))
    }
}

/// Thin draggable divider with an enlarged invisible hit area and a
/// resize-cursor on hover. Reports drag deltas to the parent so the
/// parent owns the width state and the clamping rules.
private struct DividerView: View {
    /// Visible separator thickness — the 1pt grey line the user sees.
    static let thickness: CGFloat = 1
    /// Drag-target width — wider than the visible line so the user can
    /// grab the divider without pixel-perfect aiming.
    static let hitArea: CGFloat = 17
    /// Layout-reserved width. The body's ZStack sizes to its widest child,
    /// so the divider takes `hitArea` worth of horizontal space in the
    /// HStack regardless of the visible thickness. Parents that need to
    /// budget total width must use THIS value, not `thickness`.
    static let layoutWidth: CGFloat = hitArea
    let onDrag: (CGFloat) -> Void
    let onDragStart: () -> Void
    let onDragEnd: () -> Void

    @State private var isActive = false

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
        .contentShape(Rectangle().inset(by: -4))
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if !isActive {
                        isActive = true
                        onDragStart()
                    }
                    onDrag(value.translation.width)
                }
                .onEnded { _ in
                    isActive = false
                    onDragEnd()
                }
        )
    }
}
