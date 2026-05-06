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
        /// AVSpeechSynthesisVoice identifier for the Speak Selection feature.
        /// Empty/missing falls back to the system default for the current locale.
        static let speechVoiceIdentifier = "speech.voiceIdentifier"
        /// AVSpeechUtterance.rate (0.0…1.0). Missing falls back to the SDK
        /// default (`AVSpeechUtteranceDefaultSpeechRate`).
        static let speechRate = "speech.rate"
        /// Bundle identifier of the user's preferred external IDE/editor.
        static let preferredIDE = "editor.preferredIDE"
    }

    static var claudeDangerousSkipPermissions: Bool {
        UserDefaults.standard.bool(forKey: Keys.claudeDangerousSkipPermissions)
    }

    static var codexDangerousBypass: Bool {
        UserDefaults.standard.bool(forKey: Keys.codexDangerousBypass)
    }
}
