import AppKit
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
        // We forward a small subset of surface-scoped events to the owning
        // GhosttyTerminalView so it can drive its tab's status indicator
        // (working / awaiting / completed / failed). Everything else — splits,
        // tabs, fullscreen, etc. — is unimplemented in v1.
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        let surfaceHandle = target.target.surface
        guard let userdata = ghostty_surface_userdata(surfaceHandle) else {
            return false
        }
        let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()

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
