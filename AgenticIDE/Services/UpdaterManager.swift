import AppKit
import Sparkle
import SwiftUI

/// Owns the Sparkle updater controller for the lifetime of the app.
///
/// Sparkle reads `SUFeedURL` and `SUPublicEDKey` from Info.plist; both are set
/// via the `INFOPLIST_KEY_SU*` build settings on the AgenticIDE target. The
/// controller exposes auto-checks and a manual "Check for Updates…" action.
@MainActor
final class UpdaterManager: ObservableObject {
    let controller: SPUStandardUpdaterController

    /// Drives the SwiftUI menu item's enabled state — Sparkle disables the
    /// command while a check is already in flight.
    @Published var canCheckForUpdates: Bool = true

    init() {
        // `startingUpdater: true` schedules the periodic check loop; the
        // interval is configured in Sparkle's settings UI / defaults. Manual
        // checks always work regardless.
        self.controller = SPUStandardUpdaterController(startingUpdater: true,
                                                       updaterDelegate: nil,
                                                       userDriverDelegate: nil)
        self.controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
