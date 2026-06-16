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
        /// Prefix invocation for the Ask overlay (⌘⇧A). The user's prompt is
        /// appended as a single-quoted positional argument, so the value is
        /// "everything before the prompt." Defaults to `claude -p`.
        ///
        /// Legacy: superseded by the provider/model/effort picker in the
        /// overlay composer (`ask.provider` + the per-provider keys below).
        /// Kept only so older defaults don't error on read.
        static let askCommand = "ask.command"
        /// Selected Ask provider raw value (`AskProvider.rawValue`).
        static let askProvider = "ask.provider"
        /// Last-used model id per provider, keyed `ask.model.<provider>`.
        static func askModel(_ provider: AskProvider) -> String { "ask.model.\(provider.rawValue)" }
        /// Last-used effort per provider, keyed `ask.effort.<provider>`.
        static func askEffort(_ provider: AskProvider) -> String { "ask.effort.\(provider.rawValue)" }
        /// Whether to play a sound when an agent finishes a turn
        /// (TerminalTab status flips working → completed/failed).
        static let completionSoundEnabled = "notifications.completionSoundEnabled"
        /// Name of the completion sound: a system sound name (e.g. "Glass")
        /// or `CompletionSoundPlayer.customSoundToken` for the imported file.
        static let completionSoundName = "notifications.completionSoundName"
        /// Absolute path of the imported custom sound inside
        /// `~/Library/Application Support/AgenticIDE/sounds/`.
        static let customCompletionSoundPath = "notifications.customCompletionSoundPath"
    }

    static var claudeDangerousSkipPermissions: Bool {
        UserDefaults.standard.bool(forKey: Keys.claudeDangerousSkipPermissions)
    }

    static var codexDangerousBypass: Bool {
        UserDefaults.standard.bool(forKey: Keys.codexDangerousBypass)
    }

    /// Prefix command for the Ask overlay. Whatever the user enters gets
    /// `' <escaped-prompt>'` appended, so values like `claude -p`,
    /// `codex exec`, or `gemini chat` all work.
    static var askCommand: String {
        let stored = UserDefaults.standard.string(forKey: Keys.askCommand)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return stored.isEmpty ? "claude -p" : stored
    }

    // MARK: - Ask overlay provider/model/effort

    /// Provider the Ask overlay last used. Defaults to Claude.
    static var askProvider: AskProvider {
        get {
            UserDefaults.standard.string(forKey: Keys.askProvider)
                .flatMap(AskProvider.init(rawValue:)) ?? .claude
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.askProvider) }
    }

    /// Model last used for `provider`, resolved against its current catalogue.
    static func askModel(for provider: AskProvider) -> AskModel {
        provider.model(id: UserDefaults.standard.string(forKey: Keys.askModel(provider)))
    }

    static func setAskModel(_ model: AskModel, for provider: AskProvider) {
        UserDefaults.standard.set(model.id, forKey: Keys.askModel(provider))
    }

    /// Effort last used for `provider`, clamped to what it supports.
    static func askEffort(for provider: AskProvider) -> AskEffort {
        let stored = UserDefaults.standard.string(forKey: Keys.askEffort(provider))
            .flatMap(AskEffort.init(rawValue:)) ?? provider.defaultEffort
        return provider.effort(stored)
    }

    static func setAskEffort(_ effort: AskEffort, for provider: AskProvider) {
        UserDefaults.standard.set(effort.rawValue, forKey: Keys.askEffort(provider))
    }

    /// Whether the given provider should run with its "skip safety prompts"
    /// flag, reusing the existing per-CLI toggles from Settings → Agents.
    static func askDangerous(for provider: AskProvider) -> Bool {
        switch provider {
        case .claude: return claudeDangerousSkipPermissions
        case .codex:  return codexDangerousBypass
        }
    }
}
