import AppKit
import SwiftUI

/// SwiftUI wrapper around `NSTextView` configured for source-code editing:
/// monospaced font, no smart substitutions, multi-level undo, find bar
/// (`⌘F`), line-number gutter, dark/light tracked.
///
/// Edits flow: user types in `NSTextView` → `Coordinator.textDidChange` →
/// writes to `tab.text`. External changes flow back: `updateNSView` notices
/// `tab.text` has diverged from the storage and rewrites the storage in
/// place. The `Coordinator.isApplyingExternalChange` flag prevents the
/// resulting delegate callback from re-firing into the buffer.
struct CodeEditor: NSViewRepresentable {
    @Bindable var tab: EditorTab
    /// Called once after the view is created and once each time the tab
    /// becomes the active tab. Used by the parent to plumb `⌘S` into a
    /// per-pane action — we need a path back to the live `NSTextView` to
    /// commit any in-progress IME composition before we read `tab.text`.
    var onResolved: ((NSTextView) -> Void)?
    /// When `true`, the editor disables editing entirely. Used by the
    /// diff view's HEAD panel — the user shouldn't be able to mutate the
    /// "before" buffer.
    var readOnly: Bool = false
    /// Static text override for read-only views (HEAD panel of the diff
    /// view). When set, `tab.text` is ignored and this is shown instead.
    var staticText: String?

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        configure(textView)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        // Line number gutter. Width grows automatically as the document does
        // (handled inside the ruler view itself).
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        // Read-only mode: disable editing entirely so the diff view's
        // HEAD panel can't be mutated. Selection is still allowed so users
        // can copy text out.
        textView.isEditable = !readOnly

        // First render of the active tab — load the buffer + selection now,
        // not on the next runloop turn, so the editor doesn't flash empty.
        let initialText = staticText ?? tab.text
        applyText(initialText, to: textView, coordinator: context.coordinator)
        if let state = tab.viewState {
            textView.selectedRange = clamp(state.selection, in: textView.string)
            DispatchQueue.main.async {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: state.scrollY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        onResolved?(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Keep edit-ability in sync — toggling read-only across diff/normal
        // mode without recreating the view.
        textView.isEditable = !readOnly

        // Tab swap: SwiftUI handed us a CodeEditor for a different tab than
        // the coordinator was tracking. Save the outgoing tab's view state,
        // load the incoming one's text + view state.
        if context.coordinator.tab.id != tab.id {
            captureViewState(from: textView, scrollView: scrollView,
                             into: context.coordinator.tab)
            context.coordinator.tab = tab
            let nextText = staticText ?? tab.text
            applyText(nextText, to: textView, coordinator: context.coordinator)
            let state = tab.viewState ?? EditorTab.ViewState(selection: NSRange(location: 0, length: 0),
                                                              scrollY: 0)
            textView.selectedRange = clamp(state.selection, in: textView.string)
            DispatchQueue.main.async {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: state.scrollY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            onResolved?(textView)
            return
        }

        // Same tab — but the buffer might have been refreshed externally
        // (initial disk load completed, file reverted, etc). When in static-
        // text mode (HEAD panel of the diff view), only re-sync if the
        // overridden text changed.
        let target = staticText ?? tab.text
        if textView.string != target {
            applyText(target, to: textView, coordinator: context.coordinator)
        }
    }

    // MARK: - Configuration

    private func configure(_ textView: NSTextView) {
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsCharacterPickerTouchBarItem = false
        // 20pt top inset puts the first line and its gutter "1" clearly
        // below the editor pane's tab strip. Lower values let the row
        // visually merge with the tab — the "line numbers in the header"
        // look — even though the actual layout puts them below.
        textView.textContainerInset = NSSize(width: 6, height: 20)
        textView.font = Self.editorFont
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.insertionPointColor = .labelColor
        textView.typingAttributes = [
            .font: Self.editorFont,
            .foregroundColor: NSColor.labelColor
        ]

        // Soft-wrap is fine for prose, miserable for code. Force horizontal
        // overflow + explicit line endings so long lines stay long.
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                             height: CGFloat.greatestFiniteMagnitude)
        }
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
    }

    /// Replace the text storage in one shot, preserving the undo manager
    /// state but suppressing the delegate callback so we don't re-write
    /// `tab.text` from itself.
    private func applyText(_ text: String, to textView: NSTextView, coordinator: Coordinator) {
        coordinator.isApplyingExternalChange = true
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.editorFont,
            .foregroundColor: NSColor.labelColor
        ]
        if let storage = textView.textStorage {
            let attributed = NSAttributedString(string: text, attributes: attrs)
            storage.beginEditing()
            storage.setAttributedString(attributed)
            storage.endEditing()
        } else {
            textView.string = text
        }
        coordinator.isApplyingExternalChange = false
    }

    private func captureViewState(from textView: NSTextView,
                                  scrollView: NSScrollView,
                                  into tab: EditorTab) {
        tab.viewState = EditorTab.ViewState(
            selection: textView.selectedRange,
            scrollY: scrollView.contentView.bounds.origin.y
        )
    }

    private func clamp(_ range: NSRange, in string: String) -> NSRange {
        let len = (string as NSString).length
        let loc = max(0, min(range.location, len))
        let length = max(0, min(range.length, len - loc))
        return NSRange(location: loc, length: length)
    }

    /// Single source of truth for editor font. Kept on the type so the line
    /// number ruler can read the same metrics.
    static let editorFont: NSFont = NSFont.monospacedSystemFont(
        ofSize: 12.5, weight: .regular
    )

    final class Coordinator: NSObject, NSTextViewDelegate {
        var tab: EditorTab
        var isApplyingExternalChange = false
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        init(tab: EditorTab) { self.tab = tab }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalChange,
                  let tv = notification.object as? NSTextView else { return }
            tab.text = tv.string
        }
    }
}

// MARK: - Line number gutter

/// Left-margin gutter that prints the line number for every visible glyph
/// row. Width adapts to the document's max line count so it never visibly
/// jiggles as you scroll past 99/999.
final class LineNumberRulerView: NSRulerView {
    private weak var ownedTextView: NSTextView?
    private var lineStartCache: [Int] = [0]
    private var cachedString: String = ""

    init(textView: NSTextView) {
        self.ownedTextView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 36
        NotificationCenter.default.addObserver(
            self, selector: #selector(textChanged(_:)),
            name: NSText.didChangeNotification, object: textView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
        textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
        rebuildLineCache()
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func textChanged(_: Notification) {
        rebuildLineCache()
        adjustWidthIfNeeded()
        needsDisplay = true
    }

    @objc private func boundsChanged(_: Notification) {
        needsDisplay = true
    }

    /// Recompute the start-index of each line in the document. Cheap on the
    /// scale of a typical source file (single linear scan); cheaper than
    /// recounting on every draw frame as the user scrolls.
    private func rebuildLineCache() {
        guard let tv = ownedTextView else { return }
        let s = tv.string
        if s == cachedString { return }
        cachedString = s
        var starts: [Int] = [0]
        let ns = s as NSString
        let len = ns.length
        var i = 0
        while i < len {
            let ch = ns.character(at: i)
            if ch == 0x0A { // \n
                starts.append(i + 1)
            }
            i += 1
        }
        lineStartCache = starts
    }

    private func adjustWidthIfNeeded() {
        let count = lineStartCache.count
        let digits = max(2, String(count).count)
        let charWidth: CGFloat = 8 // approx for the system mono at 11pt
        let proposed = max(36, CGFloat(digits) * charWidth + 16)
        if abs(proposed - ruleThickness) > 0.5 {
            ruleThickness = proposed
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = ownedTextView,
              let layoutManager = tv.layoutManager,
              let container = tv.textContainer else { return }

        // Background.
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        // Right-edge separator.
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 0.5, y: 0, width: 0.5, height: bounds.height).fill()

        let visibleRect = tv.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect,
                                                  in: container)
        if glyphRange.length == 0 { return }
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                     actualGlyphRange: nil)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        // Find the first line that intersects the visible character range.
        let starts = lineStartCache
        var lineIndex = upperBound(starts, charRange.location) - 1
        if lineIndex < 0 { lineIndex = 0 }

        let yOffset = tv.textContainerInset.height - tv.visibleRect.origin.y

        while lineIndex < starts.count {
            let lineStart = starts[lineIndex]
            if lineStart >= NSMaxRange(charRange) { break }
            let lineGlyphIdx = layoutManager.glyphIndexForCharacter(at: lineStart)
            var effectiveRange = NSRange(location: 0, length: 0)
            let fragRect = layoutManager.lineFragmentRect(
                forGlyphAt: lineGlyphIdx,
                effectiveRange: &effectiveRange,
                withoutAdditionalLayout: true
            )
            let label = String(lineIndex + 1) as NSString
            let size = label.size(withAttributes: attrs)
            let drawRect = NSRect(
                x: ruleThickness - size.width - 6,
                y: fragRect.minY + yOffset + (fragRect.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            label.draw(in: drawRect, withAttributes: attrs)
            lineIndex += 1
        }
    }

    /// Smallest index in `arr` whose value is > `value`. Standard
    /// upper-bound binary search. `arr` is sorted ascending by construction.
    private func upperBound(_ arr: [Int], _ value: Int) -> Int {
        var lo = 0
        var hi = arr.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if arr[mid] <= value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
