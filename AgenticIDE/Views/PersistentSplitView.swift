import AppKit
import SwiftUI

/// Five-pane horizontal split view. SwiftUI-only — no `NSSplitViewController`
/// — so the bridge can't re-derive `preferredContentSize` mid-drag and shrink
/// the bridged frame. Panes 1, 2, 4 and 5 have persisted widths; the elastic
/// pane (3, or 4 when 3 is collapsed) absorbs whatever's left.
///
/// Persistence: pane widths are stored in `UserDefaults` keyed by
/// `autosaveName` (`<name>.pane1Width`, `<name>.pane2Width`,
/// `<name>.pane4Width`, `<name>.pane5Width`). Pane 5 is the optional far-right
/// Notes pane — fully removed (no rail) when collapsed.
struct PersistentSplitView<P1: View, P2: View, P3: View, P4: View, P5: View>: View {
    let autosaveName: String

    let pane1Min: CGFloat
    let pane1Initial: CGFloat
    let pane1Max: CGFloat

    let pane2Min: CGFloat
    let pane2Initial: CGFloat
    let pane2Max: CGFloat
    /// When true, pane 2 and its divider are removed from the layout and
    /// replaced by a thin reopen rail; the freed width flows to panes 3/4.
    let pane2Collapsed: Bool
    /// Invoked when the user clicks the reopen rail to bring pane 2 back.
    let onExpandPane2: (() -> Void)?
    /// When this changes, pane 2 animates to the new width (still draggable
    /// afterward). Used to widen the Explorer when a file opens and shrink it
    /// back when none are. nil = leave pane 2 at its persisted width.
    let pane2PreferredWidth: CGFloat?

    let pane3Min: CGFloat
    /// When true, pane 3 and its preceding divider are removed from the
    /// layout and pane 4 absorbs the freed width. Used by `MainWindow` to
    /// auto-hide the editor pane when no files are open.
    let pane3Collapsed: Bool

    /// Fixed width of the thin rail shown in place of a collapsed pane 2.
    /// Computed (not stored) — generic types can't have stored statics.
    static var railWidth: CGFloat { 18 }

    let pane4Min: CGFloat
    let pane4Initial: CGFloat
    let pane4Max: CGFloat

    let pane5Min: CGFloat
    let pane5Initial: CGFloat
    let pane5Max: CGFloat
    /// When true, pane 5 and its preceding divider are removed entirely (no
    /// rail) and the elastic pane absorbs the freed width. This is how the
    /// far-right Notes pane hides when closed.
    let pane5Collapsed: Bool

    let pane1: () -> P1
    let pane2: () -> P2
    let pane3: () -> P3
    let pane4: () -> P4
    let pane5: () -> P5

    @State private var pane1Width: CGFloat
    @State private var pane2Width: CGFloat
    @State private var pane4Width: CGFloat
    @State private var pane5Width: CGFloat
    @State private var dragStart1: CGFloat?
    @State private var dragStart2: CGFloat?
    @State private var dragStart4: CGFloat?
    @State private var dragStart5: CGFloat?
    @State private var isDragging: Bool = false

    init(autosaveName: String,
         pane1Min: CGFloat = 160,
         pane1Initial: CGFloat = 200,
         pane1Max: CGFloat = 360,
         pane2Min: CGFloat = 180,
         pane2Initial: CGFloat = 240,
         pane2Max: CGFloat = 480,
         pane2Collapsed: Bool = false,
         onExpandPane2: (() -> Void)? = nil,
         pane2PreferredWidth: CGFloat? = nil,
         pane3Min: CGFloat = 320,
         pane3Collapsed: Bool = false,
         pane4Min: CGFloat = 280,
         pane4Initial: CGFloat = 420,
         pane4Max: CGFloat = 900,
         pane5Min: CGFloat = 240,
         pane5Initial: CGFloat = 340,
         pane5Max: CGFloat = 680,
         pane5Collapsed: Bool = true,
         @ViewBuilder pane1: @escaping () -> P1,
         @ViewBuilder pane2: @escaping () -> P2,
         @ViewBuilder pane3: @escaping () -> P3,
         @ViewBuilder pane4: @escaping () -> P4,
         @ViewBuilder pane5: @escaping () -> P5) {
        self.autosaveName = autosaveName
        self.pane1Min = pane1Min
        self.pane1Initial = pane1Initial
        self.pane1Max = pane1Max
        self.pane2Min = pane2Min
        self.pane2Initial = pane2Initial
        self.pane2Max = pane2Max
        self.pane2Collapsed = pane2Collapsed
        self.onExpandPane2 = onExpandPane2
        self.pane2PreferredWidth = pane2PreferredWidth
        self.pane3Min = pane3Min
        self.pane3Collapsed = pane3Collapsed
        self.pane4Min = pane4Min
        self.pane4Initial = pane4Initial
        self.pane4Max = pane4Max
        self.pane5Min = pane5Min
        self.pane5Initial = pane5Initial
        self.pane5Max = pane5Max
        self.pane5Collapsed = pane5Collapsed
        self.pane1 = pane1
        self.pane2 = pane2
        self.pane3 = pane3
        self.pane4 = pane4
        self.pane5 = pane5

        let s1 = UserDefaults.standard.object(forKey: "\(autosaveName).pane1Width") as? Double
        let s2 = UserDefaults.standard.object(forKey: "\(autosaveName).pane2Width") as? Double
        let s4 = UserDefaults.standard.object(forKey: "\(autosaveName).pane4Width") as? Double
        let s5 = UserDefaults.standard.object(forKey: "\(autosaveName).pane5Width") as? Double
        let w1 = CGFloat(s1 ?? Double(pane1Initial))
        let w2 = CGFloat(s2 ?? Double(pane2Initial))
        let w4 = CGFloat(s4 ?? Double(pane4Initial))
        let w5 = CGFloat(s5 ?? Double(pane5Initial))
        self._pane1Width = State(initialValue: max(pane1Min, min(pane1Max, w1)))
        self._pane2Width = State(initialValue: max(pane2Min, min(pane2Max, w2)))
        self._pane4Width = State(initialValue: max(pane4Min, min(pane4Max, w4)))
        self._pane5Width = State(initialValue: max(pane5Min, min(pane5Max, w5)))
    }

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            // Each DividerView's ZStack stretches to its widest child —
            // the 9pt invisible hit-target — so it reserves that much layout
            // space, NOT the 1pt visible separator. `dividerCount` drops a
            // divider for each collapsed pane; a collapsed pane 2 is replaced
            // by a fixed-width reopen rail instead.
            let widths = computeWidths(total: total)
            let w1 = widths.p1
            let w2 = widths.p2
            let w3 = widths.p3
            let w4 = widths.p4
            let w5 = widths.p5

            HStack(spacing: 0) {
                pane1()
                    .frame(width: w1)
                    .clipped()

                DividerView(onDrag: { delta in dragPane1(delta: delta, total: total) },
                            onDragStart: { isDragging = true },
                            onDragEnd: { persist(); isDragging = false })

                if pane2Collapsed {
                    Pane2ReopenRail(width: Self.railWidth) { onExpandPane2?() }
                } else {
                    pane2()
                        .frame(width: w2)
                        .clipped()

                    DividerView(onDrag: { delta in dragPane2(delta: delta, total: total) },
                                onDragStart: { isDragging = true },
                                onDragEnd: { persist(); isDragging = false })
                }

                if !pane3Collapsed {
                    pane3()
                        .frame(width: w3)
                        .clipped()

                    DividerView(onDrag: { delta in dragPane4(delta: delta, total: total) },
                                onDragStart: { isDragging = true },
                                onDragEnd: { persist(); isDragging = false })
                }

                pane4()
                    .frame(width: w4)
                    .clipped()

                if !pane5Collapsed {
                    DividerView(onDrag: { delta in dragPane5(delta: delta, total: total) },
                                onDragStart: { isDragging = true },
                                onDragEnd: { persist(); isDragging = false })

                    pane5()
                        .frame(width: w5)
                        .clipped()
                }
            }
            .transaction { t in if isDragging { t.animation = nil } }
            .frame(width: total, height: geo.size.height, alignment: .leading)
            // Belt-and-braces clip — even if the maths above had a
            // miscalculation, content can never paint outside the
            // GeometryReader's reported bounds.
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // When the preferred width changes (e.g. a file opens → widen the
        // Explorer, or the last file closes → shrink it), animate pane 2 to it.
        // The user can still drag afterward.
        .onChange(of: pane2PreferredWidth) { _, newValue in
            guard let target = newValue else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                pane2Width = clamp(target, min: pane2Min, max: pane2Max)
            }
            UserDefaults.standard.set(Double(pane2Width), forKey: "\(autosaveName).pane2Width")
        }
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
    /// Number of draggable dividers currently in the layout: one after pane 1,
    /// plus one after each of panes 2/3 that isn't collapsed.
    private var dividerCount: CGFloat {
        1 + (pane2Collapsed ? 0 : 1) + (pane3Collapsed ? 0 : 1) + (pane5Collapsed ? 0 : 1)
    }

    private func computeWidths(total: CGFloat) -> (p1: CGFloat, p2: CGFloat, p3: CGFloat, p4: CGFloat, p5: CGFloat) {
        let dividers = DividerView.layoutWidth * dividerCount
        // A collapsed pane 2 reserves a fixed-width rail instead of a pane.
        let rail = pane2Collapsed ? Self.railWidth : 0
        let usable = max(0, total - dividers - rail)
        var w1 = clamp(pane1Width, min: pane1Min, max: pane1Max)
        var w2 = pane2Collapsed ? 0 : clamp(pane2Width, min: pane2Min, max: pane2Max)
        var w4 = clamp(pane4Width, min: pane4Min, max: pane4Max)
        var w5 = pane5Collapsed ? 0 : clamp(pane5Width, min: pane5Min, max: pane5Max)
        var w3 = pane3Collapsed ? 0 : max(pane3Min, usable - w1 - w2 - w4 - w5)

        // Collapsed mode: pane 3 is zero-width and pane 4 swallows the
        // freed space (so the layout still fills the window). `pane4Max`
        // is intentionally bypassed — capping it here would leave a gap
        // on the right edge of wide windows; the collapse is meant to be
        // edge-to-edge. The Notes pane (5) keeps its persisted width on the
        // right, but never starves pane 4 below its min — on a narrow window
        // the notes pane gives up width first.
        if pane3Collapsed {
            w3 = 0
            w5 = min(w5, max(0, usable - w1 - w2 - pane4Min))
            w4 = max(pane4Min, usable - w1 - w2 - w5)
            return (w1, w2, w3, w4, w5)
        }

        var overflow = (w1 + w2 + w3 + w4 + w5) - usable
        if overflow > 0 {
            // Shrink the Notes pane (5) first, down to its min.
            let take5 = min(max(0, w5 - pane5Min), overflow)
            w5 -= take5
            overflow -= take5

            // Then pane 4, down to its min.
            if overflow > 0 {
                let take4 = min(max(0, w4 - pane4Min), overflow)
                w4 -= take4
                overflow -= take4
            }

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
        let sum = w1 + w2 + w3 + w4 + w5
        if sum > usable && sum > 0 {
            let scale = usable / sum
            w1 *= scale
            w2 *= scale
            w3 *= scale
            w4 *= scale
            w5 *= scale
        }
        return (w1, w2, w3, w4, w5)
    }

    // MARK: - Drag handlers

    /// Width the Notes pane occupies (0 when collapsed). Subtracted from the
    /// space the other dividers may claim so a drag can't push the layout into
    /// the Notes pane.
    private var pane5Region: CGFloat { pane5Collapsed ? 0 : pane5Width }

    /// Positive delta = mouse moved right = pane 1 grows. Pulled width comes
    /// from pane 3 (the elastic middle). Pane 2 stays at its persisted width
    /// unless the layout would otherwise violate pane 3's minimum.
    private func dragPane1(delta: CGFloat, total: CGFloat) {
        let start = dragStart1 ?? pane1Width
        if dragStart1 == nil { dragStart1 = start }
        let dividers = DividerView.layoutWidth * dividerCount
        let pane2Region = pane2Collapsed ? Self.railWidth : pane2Width
        let elasticMinimum = (pane3Collapsed ? pane4Min : pane3Min + pane4Width) + pane5Region
        let maxAllowed = total - pane2Region - elasticMinimum - dividers
        pane1Width = clamp(start + delta, min: pane1Min, max: min(pane1Max, maxAllowed))
    }

    /// Positive delta = mouse moved right = pane 2 grows. Only reachable when
    /// pane 2 is visible (the collapsed rail has no divider).
    private func dragPane2(delta: CGFloat, total: CGFloat) {
        let start = dragStart2 ?? pane2Width
        if dragStart2 == nil { dragStart2 = start }
        let dividers = DividerView.layoutWidth * dividerCount
        let elasticMinimum = (pane3Collapsed ? pane4Min : pane3Min + pane4Width) + pane5Region
        let maxAllowed = total - pane1Width - elasticMinimum - dividers
        pane2Width = clamp(start + delta, min: pane2Min, max: min(pane2Max, maxAllowed))
    }

    /// Positive delta = mouse moved right = pane 4 shrinks.
    private func dragPane4(delta: CGFloat, total: CGFloat) {
        let start = dragStart4 ?? pane4Width
        if dragStart4 == nil { dragStart4 = start }
        let dividers = DividerView.layoutWidth * dividerCount
        let pane2Region = pane2Collapsed ? Self.railWidth : pane2Width
        let maxAllowed = total - pane1Width - pane2Region - pane3Min - pane5Region - dividers
        pane4Width = clamp(start - delta, min: pane4Min, max: min(pane4Max, maxAllowed))
    }

    /// Positive delta = mouse moved right = the Notes pane (5) shrinks; the
    /// elastic pane (4 when pane 3 is collapsed) absorbs the freed width. Only
    /// reachable when pane 5 is visible — collapsing it removes the divider.
    private func dragPane5(delta: CGFloat, total: CGFloat) {
        let start = dragStart5 ?? pane5Width
        if dragStart5 == nil { dragStart5 = start }
        let dividers = DividerView.layoutWidth * dividerCount
        let pane2Region = pane2Collapsed ? Self.railWidth : pane2Width
        // Leave the elastic pane(s) their minimum on the left of the divider.
        let leftMinimum = pane1Width + pane2Region
            + (pane3Collapsed ? pane4Min : pane3Min + pane4Min)
        let maxAllowed = total - leftMinimum - dividers
        pane5Width = clamp(start - delta, min: pane5Min, max: min(pane5Max, maxAllowed))
    }

    private func persist() {
        dragStart1 = nil
        dragStart2 = nil
        dragStart4 = nil
        dragStart5 = nil
        UserDefaults.standard.set(Double(pane1Width), forKey: "\(autosaveName).pane1Width")
        UserDefaults.standard.set(Double(pane2Width), forKey: "\(autosaveName).pane2Width")
        UserDefaults.standard.set(Double(pane4Width), forKey: "\(autosaveName).pane4Width")
        UserDefaults.standard.set(Double(pane5Width), forKey: "\(autosaveName).pane5Width")
    }

    private func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.max(lo, Swift.min(hi, value))
    }
}

/// Thin clickable rail shown where pane 2 was, when it's collapsed. Clicking
/// it (or the ⌘⌥B shortcut) brings the file-tree pane back.
private struct Pane2ReopenRail: View {
    let width: CGFloat
    let onExpand: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            // Just the toggle, sitting in the header band at the top. No
            // trailing border and no material — the rail blends into the
            // surrounding panes so the collapsed file tree is unobtrusive.
            Button(action: onExpand) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: DS.Icon.small, weight: .semibold))
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .frame(width: width, height: DS.Control.header)
                    .background(Color.primary.opacity(isHovered ? 0.08 : 0.0))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help("Show panel (⌘⌥B)")

            Spacer(minLength: 0)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        // Match the surrounding control-surface panes (and avoid the
        // wallpaper-tinted windowBackgroundColor) so the collapsed rail blends
        // in regardless of window-active state.
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// Thin draggable divider with an enlarged invisible hit area and a
/// resize-cursor on hover. Reports drag deltas to the parent so the
/// parent owns the width state and the clamping rules.
private struct DividerView: View {
    /// Visible separator thickness — the 1pt grey line the user sees.
    static let thickness: CGFloat = 1
    /// Layout-reserved width. Kept small (≈ the card padding) so the gap at a
    /// divider matches the gap at the window edges. The actual grab target is
    /// widened beyond this via `contentShape(...inset(-5))`, so the divider is
    /// still easy to grab without reserving a big visible gap.
    static let hitArea: CGFloat = 8
    /// Layout-reserved width. The body's ZStack sizes to its widest child,
    /// so the divider takes `hitArea` worth of horizontal space in the
    /// HStack regardless of the visible thickness. Parents that need to
    /// budget total width must use THIS value, not `thickness`.
    static let layoutWidth: CGFloat = hitArea
    let onDrag: (CGFloat) -> Void
    let onDragStart: () -> Void
    let onDragEnd: () -> Void

    @State private var isActive = false
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(separatorColor)
                .frame(width: isHovered || isActive ? 2 : Self.thickness)
            Rectangle()
                .fill(Color.primary.opacity(isHovered || isActive ? 0.05 : 0.001))
                .frame(width: Self.hitArea)
            CursorTrackingView(isHovered: $isHovered)
                .frame(width: Self.hitArea)
        }
        .frame(maxHeight: .infinity)
        // Grab target extends well beyond the slim reserved width so the
        // divider stays easy to grab even though it only reserves 8pt.
        .contentShape(Rectangle().inset(by: -6))
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

    private var separatorColor: Color {
        if isActive {
            return Color.accentColor.opacity(0.85)
        }
        if isHovered {
            return Color.accentColor.opacity(0.65)
        }
        // Hidden at rest — the cards provide their own borders, so the pane
        // separators only appear (as a faint accent) while hovering/dragging.
        return Color.clear
    }
}

private struct CursorTrackingView: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> CursorTrackingNSView {
        let view = CursorTrackingNSView()
        view.onHoverChange = { hovering in
            DispatchQueue.main.async {
                isHovered = hovering
            }
        }
        return view
    }

    func updateNSView(_ nsView: CursorTrackingNSView, context: Context) {
        nsView.onHoverChange = { hovering in
            DispatchQueue.main.async {
                isHovered = hovering
            }
        }
        nsView.needsDisplay = true
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class CursorTrackingNSView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }
}
