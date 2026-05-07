import Foundation
import Observation

/// One open file in the editor pane. Reference-typed (`@Observable` class)
/// because both the tab bar and the `NSTextView` wrapper hold the same
/// instance, and edits through the text view need to flow back to the bar's
/// dirty indicator without copy-on-write hops.
///
/// `text` is the live buffer the editor displays; `savedText` is the version
/// last written to disk. Dirty = `text != savedText`. On disk read failure
/// we surface a banner via `loadError` rather than open a blank tab — the
/// user shouldn't be allowed to "save" over content we never read.
@Observable
final class EditorTab: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    var displayName: String
    var text: String = ""
    var savedText: String = ""
    var loadError: String?
    /// Reading binary files as UTF-8 always fails, but distinguishing "binary"
    /// from "we couldn't open it at all" lets us show a friendlier message.
    var isBinary: Bool = false

    /// Tracks whether content has been read from disk yet. Used by the editor
    /// to show a placeholder while loading instead of a flashing empty buffer.
    var didLoad: Bool = false

    /// True when the user has toggled the side-by-side HEAD-vs-working diff
    /// view for this tab. Lives on the tab so it survives tab switches.
    var showingDiff: Bool = false
    /// Cached HEAD-version contents for the diff view's "before" panel.
    /// Populated lazily the first time the diff toggle is flipped on.
    var headText: String?
    /// True if loading the HEAD version failed (file not in HEAD, untracked,
    /// not a git repo). The diff view shows a placeholder in that case.
    var headLoadFailed: Bool = false

    /// Selection + scroll captured each time the user switches away from this
    /// tab so we can restore them when they switch back. Both nil until the
    /// tab has been visited at least once. Held as a struct value (not via
    /// the NSTextView itself) so the editor pane can rebind to a different
    /// tab without us holding onto a dangling AppKit reference.
    struct ViewState: Equatable {
        var selection: NSRange
        var scrollY: CGFloat
    }
    var viewState: ViewState?

    init(url: URL) {
        self.url = url
        self.displayName = url.lastPathComponent
    }

    var isDirty: Bool { text != savedText }

    static func == (lhs: EditorTab, rhs: EditorTab) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
