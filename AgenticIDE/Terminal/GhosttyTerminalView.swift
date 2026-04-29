import AppKit
import Carbon.HIToolbox
import GhosttyKit
import Metal
import OSLog

/// Configuration for the PTY a surface will spawn.
struct SurfaceConfig {
    /// Single shell command line; nil means use the user's default login shell.
    var command: String?
    /// Working directory for the spawned process.
    var workingDirectory: URL?
    /// Extra environment variables (merged on top of the inherited env).
    var env: [String: String]
}

/// NSView that hosts a single Ghostty surface. Backed by a CAMetalLayer that
/// Ghostty's renderer draws into directly. Owns its `ghostty_surface_t` —
/// one view, one surface, lifetime tied to this object.
final class GhosttyTerminalView: NSView, NSTextInputClient {
    private let log = Logger(subsystem: "com.fabio.AgenticIDE", category: "GhosttyTerminalView")

    private let config: SurfaceConfig
    private var surface: ghostty_surface_t?

    private var markedText = NSMutableAttributedString()
    private var imeMarkedRange = NSRange(location: NSNotFound, length: 0)
    private var imeSelectedRange = NSRange(location: NSNotFound, length: 0)

    // MARK: - Smart-rename hook
    //
    // Tracks the user's most recently typed line so the host (TerminalTab)
    // can rename a tab to that line. We accumulate printable input, handle
    // Backspace, and clear on cursor / control keys that imply non-line edits.
    // On Return we hand the buffer to `onUserSubmitLine` and reset.

    /// Called on the main thread when the user presses Return after typing
    /// a non-empty line. The string contains everything they typed since the
    /// previous Return / cancel.
    var onUserSubmitLine: ((String) -> Void)?
    private var lineBuffer: String = ""

    /// Called on the main thread for every terminal lifecycle event we care
    /// about (BEL, OSC-9;4 progress, shell-integration command-finished, child
    /// exit). The owning `TerminalTab` folds these into a `TerminalTabStatus`.
    var onTerminalEvent: ((TerminalEvent) -> Void)?

    /// Cursor Ghostty has asked us to display. Driven by
    /// `GHOSTTY_ACTION_MOUSE_SHAPE`. Defaults to I-beam (text editing) so the
    /// terminal feels right before any process changes it. Mutating the value
    /// invalidates the cursor rects so AppKit picks up the new cursor on the
    /// next mouse move.
    private var currentCursor: NSCursor = .iBeam {
        didSet {
            guard oldValue !== currentCursor else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    /// URL of the link currently under the cursor, if any. Set by
    /// `GHOSTTY_ACTION_MOUSE_OVER_LINK`. Reserved for future tooltip / status
    /// bar use; the actual cursor change comes through `MOUSE_SHAPE`.
    private(set) var hoveredLinkURL: String?

    /// `mach_absolute_time` of the last `.render` event we let through to
    /// main. Used by the C action callback to throttle the firehose down to
    /// ~20 Hz — well below the per-streamed-token rate of any AI CLI but
    /// still enough to keep the gap-filter in `TerminalTab` correctly
    /// classifying bursts of output as "still working." Read/written from
    /// the libxev thread; mutating without a lock is safe because Ghostty
    /// dispatches per-surface action callbacks serially.
    @ObservationIgnored
    private var lastRenderDispatchHostTime: UInt64 = 0
    /// Minimum interval between `.render` dispatches in mach-absolute units.
    /// Computed once from `mach_timebase_info` so the comparison stays a
    /// single 64-bit subtract on the hot path.
    private static let renderThrottleAbsTime: UInt64 = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let nanos: UInt64 = 50_000_000  // 50 ms
        return nanos * UInt64(info.denom) / UInt64(info.numer)
    }()

    init(config: SurfaceConfig) {
        self.config = config
        super.init(frame: .zero)
        commonInit()
        attachSurfaceIfNeeded()
    }

    required init?(coder: NSCoder) {
        self.config = SurfaceConfig(command: nil, workingDirectory: nil, env: [:])
        super.init(coder: coder)
        commonInit()
        attachSurfaceIfNeeded()
    }

    private func commonInit() {
        // Layer-hosting (custom layer assigned via `self.layer =`): AppKit
        // does NOT auto-resize the layer when the view's frame changes.
        // We sync `layer.frame` ourselves in `setFrameSize` / `layout`.
        wantsLayer = true
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = false
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.masksToBounds = true
        metalLayer.frame = bounds
        self.layer = metalLayer
        self.layerContentsRedrawPolicy = .duringViewResize
        self.autoresizingMask = [.width, .height]

        let opts: NSTrackingArea.Options = [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate]
        let area = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    deinit {
        if let surface {
            // ghostty_surface_free reaps the PTY child and tears down the
            // renderer, which can take a few hundred ms. Hand the handle off
            // to a background queue so the close click returns immediately
            // and the SwiftUI re-render isn't blocked.
            let handle = surface
            self.surface = nil
            DispatchQueue.global(qos: .background).async {
                ghostty_surface_free(handle)
            }
        }
    }

    /// Optional hook callers can use to release the ghostty surface eagerly
    /// instead of waiting for ARC. Useful when a tab is closed but its NSView
    /// might be retained briefly by the SwiftUI representable cache.
    func tearDown() {
        guard let handle = surface else { return }
        surface = nil
        DispatchQueue.global(qos: .background).async {
            ghostty_surface_free(handle)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    /// Maps a Ghostty mouse-shape request to the closest NSCursor and pushes
    /// it as the view's active cursor. The most important case is `POINTER`,
    /// which Ghostty fires while the mouse is over a clickable URL — without
    /// this the cursor stays as I-beam and links don't *feel* clickable.
    func applyMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        currentCursor = Self.nsCursor(for: shape)
    }

    /// Stores the URL of the link the mouse is currently over, or nil to
    /// clear. Currently unused beyond keeping the state — wired now so a
    /// future hover-tooltip / status-bar consumer has the data without
    /// another action-callback round trip.
    func setHoveredLink(_ url: String?) {
        hoveredLinkURL = url
    }

    /// Mark this surface occluded (when its tab goes inactive). Ghostty
    /// stops painting and the metal layer is hidden so CoreAnimation stops
    /// compositing it — together that removes the GPU/CPU cost of background
    /// AI streams the user can't see. Re-activating refreshes the surface
    /// so it pops back to current state without waiting for a keystroke.
    ///
    /// Early-out when already in the requested state. `updateNSView` fires
    /// on every parent SwiftUI redraw and calls `setOccluded(!isActive)`
    /// regardless of whether anything changed; without the guard, every
    /// workspace redraw paid for a C call + CALayer toggle (and a
    /// `surface_refresh` when un-occluding) per terminal in the ZStack.
    func setOccluded(_ occluded: Bool) {
        guard let surface else { return }
        if let metal = layer as? CAMetalLayer, metal.isHidden == occluded {
            return
        }
        // Ghostty's C function name says "occlusion", but the boolean it
        // accepts is `visible`. Passing `occluded` freezes a tab as soon as
        // it becomes visible again.
        ghostty_surface_set_occlusion(surface, !occluded)
        if let metal = layer as? CAMetalLayer {
            metal.isHidden = occluded
        }
        if !occluded {
            ghostty_surface_refresh(surface)
        }
    }

    /// Called from `GhosttyApp.actionCallback` on the libxev thread for
    /// every `GHOSTTY_ACTION_RENDER` event. Returns true to forward a
    /// `.render` event to main, false to drop it. Throttles the firehose
    /// to ~20 Hz: AI streaming runs at 200–400 ms/token so we never lose
    /// burst classification, but a runaway repaint loop can no longer
    /// flood the main runloop with per-frame dispatch_async.
    func shouldDispatchRender() -> Bool {
        let now = mach_absolute_time()
        let last = lastRenderDispatchHostTime
        if last != 0 && now &- last < Self.renderThrottleAbsTime {
            return false
        }
        lastRenderDispatchHostTime = now
        return true
    }

    /// Presents the current terminal frame into the CAMetalLayer. Ghostty
    /// emits `GHOSTTY_ACTION_RENDER` when the grid/renderer is dirty; because
    /// AgenticIDE installs an action callback for status tracking, we must
    /// explicitly draw the surface after handling that action.
    func drawSurface() {
        guard let surface, window != nil else { return }
        if let metal = layer as? CAMetalLayer, metal.isHidden { return }
        ghostty_surface_draw(surface)
    }

    private func applyCurrentColorScheme(refresh: Bool = false) {
        guard let surface else { return }
        ghostty_surface_set_color_scheme(surface, Self.colorScheme(for: effectiveAppearance))
        if refresh {
            ghostty_surface_refresh(surface)
        }
    }

    private static func colorScheme(for appearance: NSAppearance) -> ghostty_color_scheme_e {
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    private static func nsCursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: return .arrow
        case GHOSTTY_MOUSE_SHAPE_POINTER: return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT: return .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL: return .crosshair
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: return .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_COPY: return .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS: return .dragLink
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
            return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_GRAB: return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING, GHOSTTY_MOUSE_SHAPE_MOVE: return .closedHand
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE: return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: return .resizeUpDown
        default: return .arrow
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        (layer as? CAMetalLayer)?.contentsScale = scale
        if let surface {
            ghostty_surface_set_content_scale(surface, scale, scale)
        }
        // After re-attaching to a window the frame may already be the size
        // we want, so AppKit doesn't fire `setFrameSize` and the metal layer
        // can show whatever stale frame it had before detach. Re-assert the
        // drawable size + surface size and request a paint.
        //
        // Two ticks: the immediate `async` catches the common case where
        // SwiftUI has already laid out by the time we re-enter the runloop;
        // the second `asyncAfter` is a belt-and-suspenders fallback for the
        // race where SwiftUI's layout pass runs after our first tick (so
        // bounds was still stale) or the metal layer's drawable wasn't ready
        // yet — without it the surface stays on its pre-detach frame until
        // the user types and ghostty marks the grid dirty.
        DispatchQueue.main.async { [weak self] in self?.refreshAfterReattach() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.refreshAfterReattach()
        }
    }

    private func refreshAfterReattach() {
        guard window != nil else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        let widthPx = UInt32(max(1, bounds.width * scale))
        let heightPx = UInt32(max(1, bounds.height * scale))
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.frame = bounds
            metalLayer.drawableSize = CGSize(width: CGFloat(widthPx), height: CGFloat(heightPx))
        }
        if let surface {
            ghostty_surface_set_size(surface, widthPx, heightPx)
            ghostty_surface_refresh(surface)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Backing scale changed — typically because the window crossed a
        // display boundary. Updating only `contents_scale` (as we used to)
        // tells Ghostty about the new DPI but leaves the metal drawable
        // and the surface's pixel dimensions sized for the *previous*
        // scale, so the grid renders into a canvas that doesn't match
        // the point-size view: visible as a cramped terminal pinned to
        // one corner of the pane after dragging across screens. Re-derive
        // pixel size from current bounds × new scale and push everything
        // through together.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let widthPx = UInt32(max(1, bounds.width * scale))
        let heightPx = UInt32(max(1, bounds.height * scale))
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = CGSize(width: CGFloat(widthPx), height: CGFloat(heightPx))
        }
        if let surface {
            ghostty_surface_set_content_scale(surface, scale, scale)
            ghostty_surface_set_size(surface, widthPx, heightPx)
            ghostty_surface_refresh(surface)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCurrentColorScheme(refresh: true)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Skip when detached / transient. SwiftUI calls `setFrameSize(.zero)`
        // on us when the parent view is removed during a project switch, and
        // forwarding that to ghostty reflows the scrollback to a 1×1 grid —
        // every cached line wraps to a single column, and the breakage
        // persists when we're re-attached. The reattach path
        // (`viewDidMoveToWindow` → `refreshAfterReattach`) re-syncs the layer
        // and surface to the real bounds, so we lose nothing by skipping.
        guard window != nil, newSize.width > 1, newSize.height > 1 else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        let widthPx = UInt32(max(1, newSize.width * scale))
        let heightPx = UInt32(max(1, newSize.height * scale))
        if let metalLayer = layer as? CAMetalLayer {
            // Layer-hosting view: we own layer sizing. Without this the layer
            // keeps its pre-resize frame, drawing past the new view bounds —
            // visible as terminal text overflowing into the right inspector
            // when the window is shrunk.
            metalLayer.frame = NSRect(origin: .zero, size: newSize)
            metalLayer.drawableSize = CGSize(width: CGFloat(widthPx), height: CGFloat(heightPx))
        }
        if let surface {
            ghostty_surface_set_size(surface, widthPx, heightPx)
            // Kick a paint. Without this, when SwiftUI sizes us *after* the
            // viewDidMoveToWindow async tick already ran on stale (zero)
            // bounds, the surface ends up at the right size with no request
            // to repaint and the metal layer keeps showing its pre-detach
            // frame until the user types.
            ghostty_surface_refresh(surface)
        }
    }

    /// Creates the underlying ghostty_surface_t, binding it to this NSView.
    /// Must be called once. The surface owns the spawned PTY process.
    private func attachSurfaceIfNeeded() {
        guard surface == nil else { return }
        guard let app = GhosttyApp.shared.app else {
            log.error("Cannot attach surface: GhosttyApp not bootstrapped")
            return
        }

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        cfg.scale_factor = scale
        cfg.context = GHOSTTY_SURFACE_CONTEXT_TAB

        // strdup the strings so they're stable for the duration of the call.
        // ghostty_surface_new copies these internally; we free our copies after.
        let cmdC: UnsafeMutablePointer<CChar>? = config.command.map { strdup($0) }
        let cwdC: UnsafeMutablePointer<CChar>? = config.workingDirectory.map { strdup($0.path) }
        defer {
            if let cmdC { free(cmdC) }
            if let cwdC { free(cwdC) }
        }
        cfg.command = UnsafePointer(cmdC)
        cfg.working_directory = UnsafePointer(cwdC)

        // Build env_vars on the heap so the pointers in ghostty_env_var_s remain
        // valid during ghostty_surface_new. Free everything after.
        let envCount = config.env.count
        var envKeys: [UnsafeMutablePointer<CChar>?] = []
        var envVals: [UnsafeMutablePointer<CChar>?] = []
        envKeys.reserveCapacity(envCount)
        envVals.reserveCapacity(envCount)
        for (k, v) in config.env {
            envKeys.append(strdup(k))
            envVals.append(strdup(v))
        }
        defer {
            for p in envKeys { if let p { free(p) } }
            for p in envVals { if let p { free(p) } }
        }

        var envEntries: [ghostty_env_var_s] = []
        envEntries.reserveCapacity(envCount)
        for i in 0..<envCount {
            envEntries.append(ghostty_env_var_s(key: UnsafePointer(envKeys[i]),
                                                 value: UnsafePointer(envVals[i])))
        }

        envEntries.withUnsafeMutableBufferPointer { buf in
            cfg.env_vars = buf.baseAddress
            cfg.env_var_count = buf.count
            guard let s = ghostty_surface_new(app, &cfg) else {
                log.error("ghostty_surface_new returned nil")
                return
            }
            self.surface = s
            ghostty_surface_set_content_scale(s, cfg.scale_factor, cfg.scale_factor)
            applyCurrentColorScheme()
        }
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        observeForLineBuffer(event)
        if let surface {
            var key = ghostty_input_key_s()
            key.action = GHOSTTY_ACTION_PRESS
            key.mods = mods(from: event.modifierFlags)
            key.consumed_mods = GHOSTTY_MODS_NONE
            key.keycode = UInt32(event.keyCode)
            key.text = nil
            key.unshifted_codepoint = 0
            key.composing = false
            if ghostty_surface_key(surface, key) { return }
        }
        interpretKeyEvents([event])
    }

    /// Updates `lineBuffer` based on which control key was pressed. Printable
    /// characters are appended later in `insertText` (so we don't have to
    /// reimplement modifier/IME handling here).
    private func observeForLineBuffer(_ event: NSEvent) {
        let kc = Int(event.keyCode)
        switch kc {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // Shift+Return = soft newline (Claude / many CLIs use this for
            // multi-line input); keep the buffer.
            if event.modifierFlags.contains(.shift) {
                lineBuffer.append("\n")
                return
            }
            let submitted = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            lineBuffer = ""
            if !submitted.isEmpty {
                onUserSubmitLine?(submitted)
            }
        case kVK_Delete:
            if !lineBuffer.isEmpty { lineBuffer.removeLast() }
        case kVK_Escape,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            // Cursor / cancel keys imply the user is editing a previous line
            // or escaping the prompt — give up on tracking this buffer.
            lineBuffer = ""
        default:
            break
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_RELEASE
        key.mods = mods(from: event.modifierFlags)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = UInt32(event.keyCode)
        key.text = nil
        key.unshifted_codepoint = 0
        key.composing = false
        _ = ghostty_surface_key(surface, key)
    }

    private func mods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if flags.contains(.shift)    { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control)  { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option)   { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command)  { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(raw)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) { forwardMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event) }
    override func mouseUp(with event: NSEvent) { forwardMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event) }
    override func rightMouseDown(with event: NSEvent) { forwardMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) }
    override func rightMouseUp(with event: NSEvent) { forwardMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) }
    override func otherMouseDown(with event: NSEvent) { forwardMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, event) }
    override func otherMouseUp(with event: NSEvent) { forwardMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, event) }

    override func mouseMoved(with event: NSEvent) { forwardMousePos(event) }
    override func mouseDragged(with event: NSEvent) { forwardMousePos(event) }
    override func rightMouseDragged(with event: NSEvent) { forwardMousePos(event) }
    override func otherMouseDragged(with event: NSEvent) { forwardMousePos(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let scrollMods: Int32 = event.hasPreciseScrollingDeltas ? 1 : 0
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, scrollMods)
    }

    private func forwardMouseButton(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent) {
        guard let surface else { return }
        forwardMousePos(event)
        _ = ghostty_surface_mouse_button(surface, state, button, mods(from: event.modifierFlags))
    }

    private func forwardMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let local = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 2.0
        let x = local.x * scale
        let y = (bounds.height - local.y) * scale
        ghostty_surface_mouse_pos(surface, x, y, mods(from: event.modifierFlags))
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String { text = s }
        else if let s = string as? NSAttributedString { text = s.string }
        else { return }
        guard let surface, !text.isEmpty else { return }
        // Capture printable input for the smart-rename buffer. Filter out
        // control characters (Return/Tab arrive separately as keyDown events
        // and are tracked via observeForLineBuffer).
        let printable = text.filter { !$0.isNewline && $0 != "\t" && !($0.asciiValue.map { $0 < 0x20 } ?? false) }
        if !printable.isEmpty { lineBuffer.append(printable) }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
        unmarkText()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let s = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: s)
        } else if let s = string as? String {
            markedText = NSMutableAttributedString(string: s)
        }
        imeMarkedRange = NSRange(location: 0, length: markedText.length)
        imeSelectedRange = selectedRange
        guard let surface else { return }
        markedText.string.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(strlen(ptr)))
        }
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        imeMarkedRange = NSRange(location: NSNotFound, length: 0)
        imeSelectedRange = NSRange(location: NSNotFound, length: 0)
        guard let surface else { return }
        ghostty_surface_preedit(surface, nil, 0)
    }

    func selectedRange() -> NSRange { imeSelectedRange }
    func markedRange() -> NSRange { imeMarkedRange }
    func hasMarkedText() -> Bool { imeMarkedRange.location != NSNotFound }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let scale = window.backingScaleFactor
        let local = NSRect(x: x / scale, y: bounds.height - y / scale - h / scale, width: w / scale, height: h / scale)
        let inWindow = convert(local, to: nil)
        return window.convertToScreen(inWindow)
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    // MARK: - Edit menu

    @objc func copy(_ sender: Any?) {
        guard let s = readSelection() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    /// Returns the user's current selection as plain text, or nil if there is
    /// no selection. Used by `copy:` for clipboard, and by the Speak Selection
    /// command for TTS.
    func readSelection() -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        let ok = ghostty_surface_read_selection(surface, &text)
        guard ok, let ptr = text.text else { return nil }
        let s = String(cString: ptr)
        ghostty_surface_free_text(surface, &text)
        return s.isEmpty ? nil : s
    }

    @objc func paste(_ sender: Any?) {
        guard surface != nil else { return }
        let pb = NSPasteboard.general

        // 1) File URLs from Finder (or any app that puts file URLs on the pasteboard):
        //    paste the shell-quoted path(s) so the agent / shell can read them.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty,
           urls.allSatisfy(\.isFileURL) {
            let joined = urls.map { Self.shellQuote($0.path) }.joined(separator: " ")
            sendText(joined)
            return
        }

        // 2) Image data on the pasteboard (e.g. screenshot, image copied from a browser
        //    or Preview): save to a temp file and paste its path. This lets agents
        //    like Claude Code pick up the image by reading the file.
        if let (data, ext) = Self.imageDataFromPasteboard(pb),
           let url = Self.saveImageToTemp(data, ext: ext) {
            sendText(Self.shellQuote(url.path))
            return
        }

        // 3) Plain text fallback (the original behavior).
        if let s = pb.string(forType: .string) {
            sendText(s)
        }
    }

    private func sendText(_ s: String) {
        guard let surface, !s.isEmpty else { return }
        s.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }

    /// Single-quote a path for safe shell pasting. Embedded single quotes are
    /// closed-escaped-reopened: foo'bar -> 'foo'\''bar'.
    private static func shellQuote(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Returns (data, extension) for the first image representation we recognise.
    /// Prefers PNG; converts TIFF to PNG when possible so agents always get a png.
    private static func imageDataFromPasteboard(_ pb: NSPasteboard) -> (Data, String)? {
        let types = pb.types ?? []
        if types.contains(.png), let data = pb.data(forType: .png) {
            return (data, "png")
        }
        if types.contains(.tiff), let data = pb.data(forType: .tiff) {
            if let rep = NSBitmapImageRep(data: data),
               let png = rep.representation(using: .png, properties: [:]) {
                return (png, "png")
            }
            return (data, "tiff")
        }
        return nil
    }

    private static func saveImageToTemp(_ data: Data, ext: String) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("AgenticIDE-paste", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = "image-\(formatter.string(from: Date())).\(ext)"
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
