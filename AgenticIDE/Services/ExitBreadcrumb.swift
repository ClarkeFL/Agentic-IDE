import Darwin
import Foundation
import OSLog

// File descriptor for the breadcrumb log. Plain file-scope global — Swift's
// `static var` accessors aren't async-signal-safe, so the signal handler
// can't go through one.
nonisolated(unsafe) private var _ebFD: Int32 = -1

private let _ebLog = Logger(subsystem: "com.fabio.AgenticIDE", category: "ExitBreadcrumb")

/// Forensic breadcrumbs for silent terminations.
///
/// We've seen AgenticIDE vanish mid-session with no crash report. The most
/// plausible cause is libghostty (Zig) hitting a panic and calling `_exit()`
/// or `abort()` directly, which bypasses Swift, AppKit, and our AppleEvent
/// handler — so the OS writes nothing. This module hooks `atexit(3)` and the
/// common fatal signals to leave at least one timestamped line at
/// `~/Library/Application Support/AgenticIDE/exit-breadcrumbs.log` per
/// termination path. Pair an unexplained `[LAUNCH]` with no `[EXIT]` line and
/// you've caught a `SIGKILL` from outside the process.
enum ExitBreadcrumb {
    static func install() {
        guard _ebFD < 0 else { return }
        openLog()
        writeLaunchLine()
        installAtExit()
        installSignalHandlers()
    }

    private static func openLog() {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = support.appendingPathComponent("AgenticIDE", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("exit-breadcrumbs.log")

        // Rotate at 256 KB so disk usage stays bounded across long-running
        // dev sessions. One backup is plenty for forensic purposes.
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = (attrs[.size] as? NSNumber)?.intValue, size > 256 * 1024 {
            let backup = url.appendingPathExtension("1")
            try? fm.removeItem(at: backup)
            try? fm.moveItem(at: url, to: backup)
        }

        _ebFD = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        if _ebFD < 0 {
            _ebLog.error("open() failed: \(String(cString: strerror(errno)), privacy: .public)")
        }
    }

    private static func writeLaunchLine() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        writeLine("[\(timestamp())] [LAUNCH] pid=\(pid) version=\(ver) build=\(build)\n")
        _ebLog.notice("breadcrumb installed pid=\(pid, privacy: .public)")
    }

    // MARK: atexit — runtime is intact, full Swift is fine.

    private static func installAtExit() {
        atexit {
            ExitBreadcrumb.writeLine("[\(ExitBreadcrumb.timestamp())] [EXIT] atexit reached pid=\(getpid())\n")
            ExitBreadcrumb.writeBacktrace()
            ExitBreadcrumb.writeLine("---\n")
        }
    }

    // MARK: signal handlers — async-signal-safe only.

    private static let handler: @convention(c) (Int32) -> Void = { sig in
        // No Swift String formatting, no allocs — only StaticString writes
        // and direct write(2) calls so this stays safe inside a signal
        // handler. Time and pid are skipped on purpose; the next [LAUNCH]
        // line gives us enough context to correlate.
        let label: StaticString
        switch sig {
        case SIGABRT: label = "[SIGNAL] SIGABRT (libc abort / Swift trap)\n"
        case SIGSEGV: label = "[SIGNAL] SIGSEGV (bad memory access)\n"
        case SIGBUS:  label = "[SIGNAL] SIGBUS (misaligned access)\n"
        case SIGILL:  label = "[SIGNAL] SIGILL (illegal instruction)\n"
        case SIGFPE:  label = "[SIGNAL] SIGFPE (floating-point exception)\n"
        case SIGTERM: label = "[SIGNAL] SIGTERM (external termination)\n"
        case SIGINT:  label = "[SIGNAL] SIGINT (interrupt)\n"
        default:      label = "[SIGNAL] (unknown)\n"
        }
        label.withUTF8Buffer { buf in
            _ = Darwin.write(_ebFD, buf.baseAddress, buf.count)
        }
        // SA_RESETHAND already restored the default disposition. Re-raise so
        // the kernel still writes a real crash report with full thread state.
        raise(sig)
    }

    private static func installSignalHandlers() {
        var sa = sigaction()
        sa.__sigaction_u.__sa_handler = handler
        sigemptyset(&sa.sa_mask)
        sa.sa_flags = SA_RESETHAND
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTERM, SIGINT] {
            sigaction(sig, &sa, nil)
        }
    }

    // MARK: helpers — fine to use freely from atexit, NOT from signal context.

    fileprivate static func writeLine(_ s: String) {
        guard _ebFD >= 0 else { return }
        s.withCString { cstr in
            _ = Darwin.write(_ebFD, cstr, strlen(cstr))
        }
    }

    fileprivate static func writeBacktrace() {
        guard _ebFD >= 0 else { return }
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let n = frames.withUnsafeMutableBufferPointer { buf in
            backtrace(buf.baseAddress, Int32(buf.count))
        }
        if n > 0 {
            frames.withUnsafeMutableBufferPointer { buf in
                backtrace_symbols_fd(buf.baseAddress, n, _ebFD)
            }
        }
    }

    fileprivate static func timestamp() -> String {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        var t = ts.tv_sec
        var tmval = tm()
        localtime_r(&t, &tmval)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d.%03d",
                      tmval.tm_year + 1900, tmval.tm_mon + 1, tmval.tm_mday,
                      tmval.tm_hour, tmval.tm_min, tmval.tm_sec,
                      Int(ts.tv_nsec / 1_000_000))
    }
}
