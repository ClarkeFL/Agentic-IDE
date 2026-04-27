import SwiftUI

/// SwiftUI wrapper around a tab's persistent NSView. The view (and its
/// underlying ghostty_surface_t) lives in the TerminalTab; this representable
/// only handles attachment to the SwiftUI tree.
struct GhosttyTerminal: NSViewRepresentable {
    let view: GhosttyTerminalView

    func makeNSView(context: Context) -> GhosttyTerminalView {
        DispatchQueue.main.async { [weak view] in
            view?.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {
        // Stateless. The view manages its own state.
    }
}
