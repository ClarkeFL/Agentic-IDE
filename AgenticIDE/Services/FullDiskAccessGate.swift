import AppKit
import Foundation
import OSLog

/// Detects + helps the user grant Full Disk Access (FDA).
///
/// Without FDA, every child process the terminal spawns (claude, node, ls,
/// cat, …) is treated by TCC as its own responsible process and re-prompts
/// the user for Documents/Downloads/Desktop access individually. With FDA on
/// AgenticIDE.app, that whole cascade short-circuits.
///
/// Apps cannot toggle FDA themselves — that's gated behind a user gesture in
/// System Settings — so the flow is:
///
///   1. Probe current status by attempting to read `~/Library/Application
///      Support/com.apple.TCC/TCC.db`. EPERM = denied, success = granted.
///      The probe doubles as the "register us in the FDA list" step: macOS
///      adds the calling app to the list as soon as it makes a TCC-protected
///      attempt, so by the time we deep-link to Settings we're already there.
///   2. `openSystemSettings()` deep-links to the FDA pane.
///   3. `startPolling()` re-probes every 1.5s while the onboarding sheet is
///      up so the UI can flip to "granted" automatically.
///   4. `relaunch()` spawns a fresh instance and quits — required because the
///      OS only checks granted-services at process launch.
@MainActor
@Observable
final class FullDiskAccessGate {
    enum Status { case granted, denied, unknown }

    /// Latest probe result. `denied` is the assumed default until `refresh()`
    /// confirms otherwise; we only bubble UI for `denied`.
    private(set) var status: Status = .unknown

    /// User has explicitly dismissed onboarding for this build. Persisted to
    /// `UserDefaults` keyed by a build-identity stamp so a fresh build (which
    /// invalidates the TCC grant under ad-hoc signing anyway — see
    /// CLAUDE.md) re-shows the prompt.
    private(set) var skippedThisBuild: Bool = false

    private var pollTimer: Timer?
    private let log = Logger(subsystem: "com.fabio.AgenticIDE", category: "FullDiskAccess")

    private static let skippedKey = "FullDiskAccessGate.skipped.buildHash"

    init() {
        refresh()
        let stored = UserDefaults.standard.string(forKey: Self.skippedKey)
        skippedThisBuild = (stored == Self.buildHash)
    }

    /// Probes FDA by attempting to open `TCC.db`. The file always exists on
    /// macOS, so a thrown error effectively always means "no permission".
    func refresh() {
        let path = ("~/Library/Application Support/com.apple.TCC/TCC.db" as NSString)
            .expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        do {
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close()
            status = .granted
        } catch {
            status = .denied
        }
    }

    /// Opens System Settings → Privacy & Security → Full Disk Access. The
    /// URL form below is supported on macOS 13+; on earlier versions it
    /// silently falls back to the Privacy section root, which is acceptable.
    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Polls FDA status every 0.3s until granted (then auto-stops). Used
    /// while the onboarding sheet is on screen and the user is over in
    /// Settings flipping the toggle. Tight cadence matters — the moment
    /// the user flips the toggle, System Settings shows its own "Quit &
    /// Reopen" prompt; we want to detect the grant and self-relaunch
    /// before they have time to click that button (which is silently
    /// refused while our modal sheet is still up).
    func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                if self.status == .granted { self.stopPolling() }
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Marks onboarding as dismissed for the current build. Naturally resets
    /// on rebuild because `buildHash` changes.
    func skipForThisBuild() {
        UserDefaults.standard.set(Self.buildHash, forKey: Self.skippedKey)
        skippedThisBuild = true
    }

    /// Spawns a fresh instance of AgenticIDE and quits the current one.
    /// Required after the user grants FDA — TCC only consults the granted-
    /// services list at process launch, so the running PID won't see the
    /// new permission.
    ///
    /// Goes through `NSWorkspace.openApplication`, *not* `Process` running
    /// `/usr/bin/open -n`. The latter makes our process the responsible
    /// parent in TCC's eyes; on ad-hoc-signed dev builds, the new instance
    /// then loses its TCC inheritance the moment we exit, and the Full Disk
    /// Access toggle for AgenticIDE in System Settings reverts to off.
    /// `openApplication` routes through LaunchServices and launchd, which
    /// is the only relaunch path that keeps TCC associations intact for a
    /// non-Developer-ID-signed build.
    func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true

        // Dismiss sheets so termination isn't refused (see
        // applicationShouldTerminate in AppDelegate for the matching
        // safety belt).
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }

        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, error in
            // Wait for the new instance to be up before tearing ourselves
            // down so the user never sees a moment with no app running.
            if let error {
                Task { @MainActor [weak self] in
                    self?.log.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
            // Hard-exit safety net on a *background* queue. A mid-
            // termination main runloop can stall main-queue dispatches and
            // skip our exit, leaving the old process alongside the new one.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.6) {
                exit(0)
            }
        }
    }

    /// Coarse build-identity stamp — bundle version + executable mtime.
    /// Both change on each `xcodebuild` so the "skip" flag invalidates
    /// across builds, matching TCC's per-cdhash behaviour for ad-hoc-signed
    /// dev builds.
    private static var buildHash: String {
        let bundleVersion = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        let mtime: TimeInterval = {
            guard let exe = Bundle.main.executableURL,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
                  let date = attrs[.modificationDate] as? Date
            else { return 0 }
            return date.timeIntervalSince1970
        }()
        return "\(bundleVersion)-\(Int(mtime))"
    }
}
