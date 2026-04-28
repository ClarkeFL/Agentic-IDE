import AppKit
import Darwin
import Foundation
import GhosttyKit
import OSLog

/// Singleton wrapping the global `ghostty_app_t`.
///
/// Ghostty's C API requires exactly one `ghostty_app_t` per process. This type
/// performs the bootstrap sequence (init → config → app) and drives the app's
/// runloop tick. Surfaces are created against this app via `GhosttySurface`.
final class GhosttyApp {
    static let shared = GhosttyApp()

    private let log = Logger(subsystem: "com.fabio.AgenticIDE", category: "GhosttyApp")

    private(set) var app: ghostty_app_t?
    private var tickTimer: Timer?

    private init() {}

    /// Performs `ghostty_init` + `ghostty_config_*` + `ghostty_app_new`.
    /// Must be called on the main thread, exactly once, at app startup.
    func bootstrap() {
        guard app == nil else { return }
        configureGhosttyResourcesEnvironment()

        // ghostty_init takes argc/argv. We pass zero args.
        var argv: [UnsafeMutablePointer<CChar>?] = [nil]
        let initResult = argv.withUnsafeMutableBufferPointer { buf in
            ghostty_init(0, buf.baseAddress)
        }
        guard initResult == GHOSTTY_SUCCESS else {
            log.error("ghostty_init failed: \(initResult)")
            return
        }

        guard let cfg = ghostty_config_new() else {
            log.error("ghostty_config_new returned nil")
            return
        }
        ghostty_config_load_default_files(cfg)
        ghostty_config_finalize(cfg)

        var rt = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: GhosttyApp.wakeupCallback,
            action_cb: GhosttyApp.actionCallback,
            read_clipboard_cb: GhosttyApp.readClipboardCallback,
            confirm_read_clipboard_cb: GhosttyApp.confirmReadClipboardCallback,
            write_clipboard_cb: GhosttyApp.writeClipboardCallback,
            close_surface_cb: GhosttyApp.closeSurfaceCallback
        )

        guard let newApp = ghostty_app_new(&rt, cfg) else {
            log.error("ghostty_app_new returned nil")
            return
        }
        ghostty_app_set_color_scheme(newApp, Self.currentColorScheme())
        self.app = newApp

        // Ghostty's embedding API needs the host to keep pumping tick() so
        // terminal state changes make it through to the Metal renderer. The
        // wakeup callback below still gives pending work an immediate tick,
        // but it is not sufficient as the only render driver: typed input and
        // process output can update the PTY/grid without the CAMetalLayer
        // presenting until another UI event forces a refresh.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let app = self.app else { return }
            ghostty_app_tick(app)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.tickTimer = timer

        log.info("Ghostty app bootstrapped")
    }

    /// The Ghostty C core expects its resources next to a normal Ghostty app
    /// bundle. Our app embeds libghostty directly, so point it at bundled
    /// resources when available and fall back to the user's installed Ghostty
    /// app during local development.
    private func configureGhosttyResourcesEnvironment() {
        if let existing = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"],
           !existing.isEmpty {
            return
        }
        guard let resourcesURL = Self.ghosttyResourcesDirectory() else {
            log.warning("Ghostty resources directory not found; terminfo, themes, and shell integration may be reduced")
            return
        }
        setenv("GHOSTTY_RESOURCES_DIR", resourcesURL.path, 0)
        log.info("Using Ghostty resources directory: \(resourcesURL.path, privacy: .public)")
    }

    private static func ghosttyResourcesDirectory() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("ghostty", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty", isDirectory: true)
        ].compactMap { $0 }
        return candidates.first(where: isValidGhosttyResourcesDirectory)
    }

    private static func isValidGhosttyResourcesDirectory(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let shellIntegrationURL = url.appendingPathComponent("shell-integration", isDirectory: true)
        guard fm.fileExists(atPath: shellIntegrationURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        isDirectory = false
        let themesURL = url.appendingPathComponent("themes", isDirectory: true)
        guard fm.fileExists(atPath: themesURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        isDirectory = false
        let terminfoURL = url.deletingLastPathComponent().appendingPathComponent("terminfo", isDirectory: true)
        return fm.fileExists(atPath: terminfoURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func currentColorScheme() -> ghostty_color_scheme_e {
        let appearance = NSApp?.effectiveAppearance ?? NSApplication.shared.effectiveAppearance
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    func shutdown() {
        tickTimer?.invalidate()
        tickTimer = nil
        if let app {
            ghostty_app_free(app)
            self.app = nil
        }
    }

    // MARK: - Runtime callbacks

    private static let wakeupCallback: ghostty_runtime_wakeup_cb = { userdata in
        // Fired by libxev (off main) whenever a surface has work pending.
        // We hop to main and call `ghostty_app_tick` so fresh PTY/input work
        // is processed promptly instead of waiting for the next timer frame.
        guard let userdata else { return }
        let owner = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            guard let handle = owner.app else { return }
            ghostty_app_tick(handle)
        }
    }

    private static let actionCallback: ghostty_runtime_action_cb = { _, target, action in
        // Surface-scoped events get forwarded to the owning GhosttyTerminalView.
        // Three groups handled here:
        //   1. Direct side-effects (open URL, cursor shape, hover state) — done
        //      inline before the TerminalEvent mapping.
        //   2. Status events (progress / bell / command-finished / exit / render)
        //      — folded into TerminalEvent for the tab's status indicator.
        //   3. Everything else (splits, tabs, fullscreen, …) — unimplemented.
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        let surfaceHandle = target.target.surface
        guard let userdata = ghostty_surface_userdata(surfaceHandle) else {
            return false
        }
        let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()

        switch action.tag {
        case GHOSTTY_ACTION_OPEN_URL:
            // Triggered by Ghostty when the user clicks (with the configured
            // modifier — by default ⌘) a URL it has detected in the grid.
            // The pointer is only valid for the duration of this callback,
            // so the string is copied out before dispatching to the main
            // queue.
            let info = action.action.open_url
            guard let urlString = makeString(info.url, length: Int(info.len)),
                  let url = URL(string: urlString) else {
                return true
            }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            // Cursor change requests come through here — most importantly
            // POINTER while hovering a click-target URL, but also TEXT/CELL
            // for normal terminal use. Without this the cursor would stay
            // on whatever AppKit picked at view creation.
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { view.applyMouseShape(shape) }
            return true
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            // Snapshot the URL (or nil to clear) for any future hover UI.
            // Cursor doesn't change here — that's MOUSE_SHAPE's job.
            let info = action.action.mouse_over_link
            let url = makeString(info.url, length: Int(info.len))
            DispatchQueue.main.async { view.setHoveredLink(url) }
            return true
        default:
            break
        }

        let event: TerminalEvent?
        switch action.tag {
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            event = .progress(progressState(from: action.action.progress_report.state))
        case GHOSTTY_ACTION_RING_BELL:
            event = .bell
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            event = .commandFinished(exitCode: Int(action.action.command_finished.exit_code))
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            event = .childExited(exitCode: Int(action.action.child_exited.exit_code))
        case GHOSTTY_ACTION_RENDER:
            // Render actions are the actual paint request. Because this
            // callback returns true, the host is responsible for presenting
            // the surface; otherwise the PTY/grid updates but the Metal layer
            // can stay frozen until another UI event forces a refresh.
            //
            // Keep drawing every render action, but throttle the separate
            // sidebar-status `.render` event so hot streams don't flood the
            // observation path.
            let dispatchStatusEvent = view.shouldDispatchRender()
            DispatchQueue.main.async {
                view.drawSurface()
                if dispatchStatusEvent {
                    view.onTerminalEvent?(.render)
                }
            }
            return true
        default:
            event = nil
        }

        guard let event else { return false }
        DispatchQueue.main.async { view.onTerminalEvent?(event) }
        return true
    }

    /// Copies a Ghostty-supplied (`const char*`, `size_t`) byte buffer into a
    /// Swift String. Returns nil for null pointer or zero length. The pointer
    /// is only valid for the duration of the action callback, so callers must
    /// extract before dispatching async work.
    private static func makeString(_ ptr: UnsafePointer<CChar>?, length: Int) -> String? {
        guard let ptr, length > 0 else { return nil }
        let data = Data(bytes: ptr, count: length)
        return String(data: data, encoding: .utf8)
    }

    private static func progressState(from raw: ghostty_action_progress_report_state_e) -> GhosttyProgressState {
        switch raw {
        case GHOSTTY_PROGRESS_STATE_SET: return .set
        case GHOSTTY_PROGRESS_STATE_REMOVE: return .remove
        case GHOSTTY_PROGRESS_STATE_ERROR: return .error
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE: return .indeterminate
        case GHOSTTY_PROGRESS_STATE_PAUSE: return .pause
        default: return .remove
        }
    }

    private static let readClipboardCallback: ghostty_runtime_read_clipboard_cb = { userdata, clipboard, state in
        // GhosttyNSView completes the clipboard request directly when needed,
        // so this default path returns false (unhandled).
        _ = userdata
        _ = clipboard
        _ = state
        return false
    }

    private static let confirmReadClipboardCallback: ghostty_runtime_confirm_read_clipboard_cb = { _, _, _, _ in
        // Auto-deny OSC-52 reads in v1.
    }

    private static let writeClipboardCallback: ghostty_runtime_write_clipboard_cb = { _, clipboard, content, count, confirm in
        guard let content = content, count > 0 else { return }
        var combined = ""
        for i in 0..<count {
            let entry = content.advanced(by: i).pointee
            if let dataPtr = entry.data {
                combined += String(cString: dataPtr)
            }
        }
        guard !combined.isEmpty else { return }
        DispatchQueue.main.async {
            let pb: NSPasteboard
            switch clipboard {
            case GHOSTTY_CLIPBOARD_SELECTION:
                pb = NSPasteboard(name: .find)
            default:
                pb = .general
            }
            pb.clearContents()
            pb.setString(combined, forType: .string)
            _ = confirm
        }
    }

    private static let closeSurfaceCallback: ghostty_runtime_close_surface_cb = { _, _ in
        // No-op in v1: surfaces are torn down explicitly by the host.
    }
}
