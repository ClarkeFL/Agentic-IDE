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
        wantsLayer = true
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.masksToBounds = true
        self.layer = metalLayer
        self.layerContentsRedrawPolicy = .duringViewResize
        self.autoresizingMask = [.width, .height]

        let opts: NSTrackingArea.Options = [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate]
        let area = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    deinit {
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        (layer as? CAMetalLayer)?.contentsScale = scale
        if let surface {
            ghostty_surface_set_content_scale(surface, scale, scale)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        (layer as? CAMetalLayer)?.contentsScale = scale
        if let surface {
            ghostty_surface_set_content_scale(surface, scale, scale)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let scale = window?.backingScaleFactor ?? 2.0
        let widthPx = UInt32(max(1, newSize.width * scale))
        let heightPx = UInt32(max(1, newSize.height * scale))
        (layer as? CAMetalLayer)?.drawableSize = CGSize(width: CGFloat(widthPx), height: CGFloat(heightPx))
        if let surface {
            ghostty_surface_set_size(surface, widthPx, heightPx)
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
        guard let surface else { return }
        var text = ghostty_text_s()
        let ok = ghostty_surface_read_selection(surface, &text)
        guard ok, let ptr = text.text else { return }
        let s = String(cString: ptr)
        ghostty_surface_free_text(surface, &text)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let surface, let s = NSPasteboard.general.string(forType: .string) else { return }
        s.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }
}
