import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Multiline chat input backed by `NSTextView` so we get the one behaviour a
/// SwiftUI `TextField` can't give us on macOS: **Return sends, Shift+Return
/// inserts a newline.** A vertical-axis `TextField` swallows Return as a
/// newline and never fires `.onSubmit`, which is the opposite of what a chat
/// composer wants. The view also self-sizes from one line up to `maxHeight`
/// and then scrolls, like every modern chat box.
struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    /// Measured content height, clamped to `[minHeight, maxHeight]`. The parent
    /// applies this as the field's frame height so the box grows as you type.
    @Binding var height: CGFloat
    var minHeight: CGFloat = 22
    var maxHeight: CGFloat = 160
    var isEnabled: Bool = true
    /// Called when Return is pressed without Shift.
    var onSend: () -> Void
    /// Called when an image is pasted into the composer (intercepted before it
    /// would otherwise be dropped, since this is a plain-text field).
    var onPasteImage: ((NSImage) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .allowed

        let textView = SendingTextView()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: DS.FontSize.body + 1)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        context.coordinator.textView = textView

        // Focus the composer as soon as it appears so the user can just type.
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        DispatchQueue.main.async { context.coordinator.recalcHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
            context.coordinator.recalcHeight()
        }
        textView.isEditable = isEnabled
        textView.isSelectable = true
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputTextView
        weak var textView: NSTextView?
        private var lastReportedHeight: CGFloat = 0

        init(_ parent: ChatInputTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            recalcHeight()
        }

        /// Intercept Return: plain Return sends, Shift+Return makes a newline.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if shift {
                textView.insertNewline(self)   // honour Shift+Return as a newline
                return true
            }
            parent.onSend()
            return true
        }

        func recalcHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let inset = textView.textContainerInset.height * 2
            let clamped = min(max(used + inset, parent.minHeight), parent.maxHeight)
            guard abs(clamped - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = clamped
            DispatchQueue.main.async { [weak self] in self?.parent.height = clamped }
        }
    }

    /// NSTextView subclass that lets Cmd+Return also send (some keyboards / IME
    /// setups deliver it as a key equivalent rather than `insertNewline:`).
    final class SendingTextView: NSTextView {
        weak var coordinator: Coordinator?
        private var hasFocusedOnce = false

        /// Grab focus once the view actually joins a window — doing it in
        /// `makeNSView` is too early (no window yet), so the composer wouldn't
        /// reliably be first responder when the overlay slides in.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !hasFocusedOnce else { return }
            hasFocusedOnce = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            let isReturn = event.keyCode == 36 || event.keyCode == 76   // Return / keypad Enter
            if isReturn, event.modifierFlags.contains(.command) {
                coordinator?.parent.onSend()
                return
            }
            super.keyDown(with: event)
        }

        /// Catch ⌘V *before* the main menu's Paste item routes it, so we
        /// reliably grab pasted images regardless of responder-chain quirks.
        /// Returns `false` when there's no image so normal text paste still
        /// runs through AppKit's own handling.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "v",
               handleImagePaste() {
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        /// Menu-driven paste (Edit ▸ Paste) of an image lands here too.
        override func paste(_ sender: Any?) {
            if handleImagePaste() { return }
            super.paste(sender)
        }

        /// Hand any image on the pasteboard to the composer as an attachment.
        /// A plain-text NSTextView would otherwise silently drop it.
        @discardableResult
        private func handleImagePaste() -> Bool {
            guard let image = Self.imageFromPasteboard() else { return false }
            coordinator?.parent.onPasteImage?(image)
            return true
        }

        /// Pull an image off the general pasteboard, trying the most reliable
        /// sources first: raw PNG/TIFF bytes (screenshots, copied images),
        /// then an `NSImage` object, then an image *file* URL (copied in Finder).
        private static func imageFromPasteboard() -> NSImage? {
            let pasteboard = NSPasteboard.general
            for type in [NSPasteboard.PasteboardType.png, .tiff] {
                if let data = pasteboard.data(forType: type), let image = NSImage(data: data) {
                    return image
                }
            }
            if let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
               image.isValid {
                return image
            }
            if let url = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
            )?.first as? URL, let image = NSImage(contentsOf: url) {
                return image
            }
            return nil
        }
    }
}
