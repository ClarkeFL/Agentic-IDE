import AppKit
import Foundation
import Observation
import OSLog

/// Lifecycle status of a terminal — surfaced in the sidebar so the user can
/// tell at a glance whether an AI agent is working or done, even when they're
/// focused on a different project.
///
/// Inferred from terminal escape sequences ghostty exposes via its action
/// callback: OSC-9;4 progress reports, BEL, render activity, and process exit.
enum TerminalTabStatus: Equatable {
    case idle
    case working
    case completed
    case failed
}

/// Per-surface terminal lifecycle event extracted from ghostty's action_cb.
/// Plumbed through `GhosttyTerminalView.onTerminalEvent` so the owning tab
/// can fold it into a `TerminalTabStatus`.
enum TerminalEvent {
    case progress(GhosttyProgressState)
    case bell
    case commandFinished(exitCode: Int)
    case childExited(exitCode: Int)
    /// Ghostty wants the host to redraw — fires whenever the terminal grid
    /// changes (data written, scroll, cursor blink, etc.). Used as a "still
    /// producing output" hint so silent transitions (tool calls) don't drop
    /// us out of `.working` prematurely.
    case render
}

/// Mirrors `ghostty_action_progress_report_state_e` so call sites don't need
/// to import GhosttyKit.
enum GhosttyProgressState {
    case set
    case remove
    case error
    case indeterminate
    case pause
}

/// One tab in a project's tab bar. Owns the persistent NSView (and its
/// underlying ghostty surface) so the spawned process keeps running across
/// tab and project switches. Ephemeral — not persisted to disk.
@Observable
final class TerminalTab: Identifiable, Hashable {
    private static let log = Logger(subsystem: "com.fabio.AgenticIDE", category: "TerminalStatus")

    let id: UUID
    var title: String
    let command: String?
    /// Captured at spawn time so the tab can be re-spawned on next launch with
    /// the same working directory.
    let workingDirectoryPath: String?
    let view: GhosttyTerminalView
    let createdAt: Date

    /// Lifecycle status surfaced in the sidebar. Updated by terminal events
    /// dispatched from `GhosttyApp.actionCallback` and cleared when the user
    /// activates the tab (so they only see "Completed" once).
    var status: TerminalTabStatus = .idle

    /// Pending working→completed transition. Claude (and most AI CLIs) emit
    /// OSC-9;4 SET/REMOVE in tight bursts during thinking and go silent
    /// during tool calls, but reliably stop emitting once a turn is over.
    /// We schedule the resolution to `.completed` after the last REMOVE and
    /// reset the timer on every new SET / output burst, so a long working
    /// session reads as one continuous "Working" until it actually settles.
    @ObservationIgnored
    private var pendingCompletion: DispatchWorkItem?

    /// Quiet time after the last progress / output event before we declare
    /// the work "done" and flip to `.completed`. Long enough to ride out
    /// mid-turn pauses, silent tool runs, and slow token-by-token streaming
    /// of the AI's final response; short enough to feel responsive once
    /// everything actually settles.
    @ObservationIgnored
    private let completionHoldSeconds: TimeInterval = 20.0

    /// Most recent ghostty render timestamp, used to detect bursts of output.
    @ObservationIgnored
    private var lastRenderAt: Date = .distantPast

    /// Render-to-render gap that still counts as activity. Streamed AI text
    /// can land at 200–400 ms intervals; ghostty's default cursor blink is
    /// ~750 ms, so this threshold catches slow streaming while filtering
    /// out an idle blink.
    @ObservationIgnored
    private let renderBurstGap: TimeInterval = 0.50

    init(id: UUID = UUID(), title: String, config: SurfaceConfig) {
        self.id = id
        self.title = title
        self.command = config.command
        self.workingDirectoryPath = config.workingDirectory?.path
        self.view = GhosttyTerminalView(config: config)
        self.createdAt = Date()
        self.view.onTerminalEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    deinit { pendingCompletion?.cancel() }

    static func == (lhs: TerminalTab, rhs: TerminalTab) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Folds a single ghostty event into the tab's status.
    ///
    /// State transitions:
    ///   any → working     on OSC-9;4 SET / INDETERMINATE
    ///   working → working on OSC-9;4 REMOVE  (timer scheduled, doesn't flip)
    ///   working → working on render burst    (timer extended)
    ///   working → completed on bell          (immediate)
    ///   working → completed on timer expiry  (last-resort fallback when the
    ///                                          AI exits cleanly without BEL)
    ///   any → completed/failed on process exit / shell-integration finish
    ///   any → failed on OSC-9;4 ERROR
    private func handle(_ event: TerminalEvent) {
        switch event {
        case .progress(let state):
            switch state {
            case .set, .indeterminate:
                cancelPendingCompletion()
                if status != .working {
                    Self.log.debug("[\(self.title)] progress SET → working")
                }
                status = .working
            case .remove:
                // Don't transition synchronously — Claude emits REMOVE
                // between thinking steps and during tool calls. Schedule
                // the resolution; a new SET / render burst will cancel.
                if status == .working { schedulePendingCompletion(reason: "progress REMOVE") }
            case .error:
                cancelPendingCompletion()
                Self.log.debug("[\(self.title)] progress ERROR → failed")
                status = .failed
            case .pause:
                // No "Question" state — pause from other programs ignored.
                break
            }
        case .bell:
            // Claude rings BEL at end of every turn. Authoritative "done"
            // signal when it fires; don't override a real failure.
            if status != .failed {
                cancelPendingCompletion()
                Self.log.debug("[\(self.title)] bell → completed")
                status = .completed
            }
        case .commandFinished(let exitCode):
            cancelPendingCompletion()
            Self.log.debug("[\(self.title)] commandFinished exit=\(exitCode)")
            status = (exitCode == 0) ? .completed : .failed
        case .childExited(let exitCode):
            cancelPendingCompletion()
            Self.log.debug("[\(self.title)] childExited exit=\(exitCode)")
            status = (exitCode == 0) ? .completed : .failed
        case .render:
            // Output activity. While we're working, treat sustained output
            // (gap < 150ms) as "still working" — extends the pending
            // completion timer so silent moments after streaming output
            // don't prematurely flip to Completed. Cursor blinks at ~2Hz
            // are rejected by the gap check so an idle-at-prompt tab does
            // eventually resolve.
            let now = Date()
            let gap = now.timeIntervalSince(lastRenderAt)
            lastRenderAt = now
            if status == .working && gap < renderBurstGap && pendingCompletion != nil {
                schedulePendingCompletion(reason: "render burst")
            }
        }
    }

    private func schedulePendingCompletion(reason: String) {
        cancelPendingCompletion()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Only resolve if we're still "working" — bell / exit might
            // have already flipped us, in which case we leave that state
            // alone.
            if self.status == .working {
                Self.log.debug("[\(self.title)] completion timer fired → completed")
                self.status = .completed
            }
            self.pendingCompletion = nil
        }
        pendingCompletion = work
        DispatchQueue.main.asyncAfter(deadline: .now() + completionHoldSeconds, execute: work)
    }

    private func cancelPendingCompletion() {
        pendingCompletion?.cancel()
        pendingCompletion = nil
    }
}
