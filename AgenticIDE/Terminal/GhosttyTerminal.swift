import SwiftUI

/// SwiftUI bridge that hosts a single Ghostty-backed terminal NSView.
struct GhosttyTerminal: NSViewRepresentable {
    func makeNSView(context: Context) -> GhosttyTerminalView {
        let view = GhosttyTerminalView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            view?.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {
        // Stateless in v1.
    }
}
