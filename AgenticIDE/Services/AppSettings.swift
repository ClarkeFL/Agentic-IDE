import Foundation

/// App-wide toggles persisted in `UserDefaults` so they survive relaunches.
/// The same keys are used with `@AppStorage` in SwiftUI views, so changes
/// from the Settings window are picked up here automatically.
enum AppSettings {
    enum Keys {
        /// `claude --dangerously-skip-permissions` — auto-accept every prompt.
        static let claudeDangerousSkipPermissions = "claude.dangerouslySkipPermissions"
        /// `codex --dangerously-bypass-approvals-and-sandbox` — same idea for
        /// the OpenAI Codex CLI ("yolo" mode).
        static let codexDangerousBypass = "codex.dangerouslyBypassApprovalsAndSandbox"
    }

    static var claudeDangerousSkipPermissions: Bool {
        UserDefaults.standard.bool(forKey: Keys.claudeDangerousSkipPermissions)
    }

    static var codexDangerousBypass: Bool {
        UserDefaults.standard.bool(forKey: Keys.codexDangerousBypass)
    }
}
