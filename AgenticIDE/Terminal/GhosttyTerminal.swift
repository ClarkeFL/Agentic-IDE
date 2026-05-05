import SwiftUI

/// SwiftUI wrapper around a tab's persistent NSView. The view (and its
/// underlying ghostty_surface_t) lives in the TerminalTab; this representable
/// only handles attachment to the SwiftUI tree.
struct GhosttyTerminal: NSViewRepresentable {
    let view: GhosttyTerminalView
    /// True when this tab is the one the user is currently looking at.
    /// Inactive tabs mark their surface occluded (Ghostty stops painting)
    /// and hide their metal layer (CoreAnimation stops compositing) so a
    /// stack of background AI streams doesn't burn GPU/CPU rendering
    /// frames the user can't see.
    let isActive: Bool

    func makeNSView(context: Context) -> GhosttyTerminalView {
        if isActive {
            DispatchQueue.main.async { [weak view] in
                view?.window?.makeFirstResponder(view)
            }
        }
        view.setOccluded(!isActive)
        return view
    }

    func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {
        nsView.setOccluded(!isActive)
        if isActive {
            nsView.needsLayout = true
        }
    }
}
