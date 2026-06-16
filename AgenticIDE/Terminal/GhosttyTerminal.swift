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
    /// When true, grab first responder on attach. In a multi-cell grid only
    /// one cell should auto-focus, so callers pass true for a single cell.
    var autoFocus: Bool = true
    /// Forwarded to the surface so the owner can track which cell is focused.
    var onFocused: (() -> Void)? = nil

    func makeNSView(context: Context) -> GhosttyTerminalView {
        view.onFocused = onFocused
        if isActive && autoFocus {
            DispatchQueue.main.async { [weak view] in
                view?.window?.makeFirstResponder(view)
            }
        }
        view.setOccluded(!isActive)
        return view
    }

    func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {
        nsView.onFocused = onFocused
        nsView.setOccluded(!isActive)
        if isActive {
            nsView.needsLayout = true
        }
    }
}
