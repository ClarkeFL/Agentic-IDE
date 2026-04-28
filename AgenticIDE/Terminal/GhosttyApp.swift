import AppKit
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
        self.app = newApp

        // Drive the app's tick on the main runloop. Ghostty internally uses
        // libxev; tick() pumps any pending work.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let app = self.app else { return }
            ghostty_app_tick(app)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.tickTimer = timer

        log.info("Ghostty app bootstrapped")
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

    private static let wakeupCallback: ghostty_runtime_wakeup_cb = { _ in
        // Wake the runloop so the next tick processes pending work.
        DispatchQueue.main.async {
            // Tick is already on a 60Hz timer; no-op is fine here.
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
            // Used as an "is the terminal still actively producing output"
            // hint so silent moments mid-turn don't drop the working
            // indicator. TerminalTab applies a gap filter to ignore the
            // steady cursor-blink renders.
            event = .render
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
