import AppKit
import SwiftUI

/// Three-pane horizontal split that persists divider positions across launches.
/// Wraps `NSSplitViewController` because SwiftUI's `HSplitView` doesn't expose
/// an autosave hook.
///
/// Notes on sizing:
///   * We avoid `preferredContentSize` and intrinsic-content sizing on the
///     hosting controllers — those add Auto Layout width constraints that
///     fight the divider drag and can compress the entire layout.
///   * Initial divider positions are set explicitly on the first layout pass
///     when no autosaved state is restored from `UserDefaults`.
struct PersistentSplitView<L: View, M: View, R: View>: NSViewControllerRepresentable {
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

    init(autosaveName: String,
         leadingMin: CGFloat = 180,
         leadingInitial: CGFloat = 240,
         leadingMax: CGFloat = 420,
         centerMin: CGFloat = 240,
         trailingMin: CGFloat = 200,
         trailingInitial: CGFloat = 280,
         // Effectively unbounded — the new git diff inspector wants room to
         // breathe when reviewing large files. Center pane has the lower
         // holding priority so it absorbs the shrink.
         trailingMax: CGFloat = .greatestFiniteMagnitude,
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
    }

    func makeNSViewController(context: Context) -> PersistentSplitController {
        let svc = PersistentSplitController()
        svc.autosaveKey = autosaveName
        svc.leadingInitial = leadingInitial
        svc.trailingInitial = trailingInitial

        svc.splitView.dividerStyle = .thin
        svc.splitView.autosaveName = autosaveName
        svc.splitView.identifier = NSUserInterfaceItemIdentifier(autosaveName)

        let leadingHost = makeHost(leading())
        let leadingItem = NSSplitViewItem(viewController: leadingHost)
        leadingItem.minimumThickness = leadingMin
        leadingItem.maximumThickness = leadingMax
        leadingItem.canCollapse = false
        leadingItem.holdingPriority = NSLayoutConstraint.Priority(260)
        svc.addSplitViewItem(leadingItem)

        let centerHost = makeHost(center())
        let centerItem = NSSplitViewItem(viewController: centerHost)
        centerItem.minimumThickness = centerMin
        centerItem.canCollapse = false
        centerItem.holdingPriority = NSLayoutConstraint.Priority(240)
        svc.addSplitViewItem(centerItem)

        let trailingHost = makeHost(trailing())
        let trailingItem = NSSplitViewItem(viewController: trailingHost)
        trailingItem.minimumThickness = trailingMin
        trailingItem.maximumThickness = trailingMax
        trailingItem.canCollapse = false
        trailingItem.holdingPriority = NSLayoutConstraint.Priority(260)
        svc.addSplitViewItem(trailingItem)

        return svc
    }

    func updateNSViewController(_ svc: PersistentSplitController, context: Context) {
        guard svc.splitViewItems.count == 3 else { return }
        (svc.splitViewItems[0].viewController as? NSHostingController<L>)?.rootView = leading()
        (svc.splitViewItems[1].viewController as? NSHostingController<M>)?.rootView = center()
        (svc.splitViewItems[2].viewController as? NSHostingController<R>)?.rootView = trailing()
    }

    /// Builds an NSHostingController that defers all sizing to its parent split
    /// item. Without zeroing `sizingOptions` the controller imposes intrinsic
    /// width constraints, which fight divider dragging.
    private func makeHost<V: View>(_ view: V) -> NSHostingController<V> {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        return host
    }
}

final class PersistentSplitController: NSSplitViewController {
    var autosaveKey: String = ""
    var leadingInitial: CGFloat = 240
    var trailingInitial: CGFloat = 280
    private var didApplyInitialPositions = false

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didApplyInitialPositions else { return }
        guard splitViewItems.count == 3 else { return }
        // If autosave restored sizes the framework already applied them by the
        // time we lay out — only apply defaults when nothing is on disk.
        if !hasAutosavedFrames {
            let total = splitView.bounds.width
            guard total > 0 else { return }
            // Divider 0: end of leading pane.
            splitView.setPosition(leadingInitial, ofDividerAt: 0)
            // Divider 1: end of center pane (= total width - trailingInitial).
            splitView.setPosition(total - trailingInitial, ofDividerAt: 1)
        }
        didApplyInitialPositions = true
    }

    private var hasAutosavedFrames: Bool {
        guard !autosaveKey.isEmpty else { return false }
        // AppKit stores split-view frames under "NSSplitView Subview Frames <name>".
        let key = "NSSplitView Subview Frames \(autosaveKey)"
        return UserDefaults.standard.object(forKey: key) != nil
    }
}
