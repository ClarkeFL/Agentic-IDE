import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// App-wide preferences. Reachable via the standard macOS "Settings…" menu
/// item (⌘,). Toggles are bound to `@AppStorage` so they persist across
/// app launches automatically.
struct SettingsView: View {
    var body: some View {
        TabView {
            AgentsSettingsView()
                .tabItem { Label("Agents", systemImage: "sparkles") }
            LaunchersSettingsView()
                .tabItem { Label("Launchers", systemImage: "square.grid.2x2") }
            EditorSettingsView()
                .tabItem { Label("Editor", systemImage: "curlybraces") }
            HooksSettingsView()
                .tabItem { Label("Hooks", systemImage: "link") }
            NotificationsSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
            SpeechSettingsView()
                .tabItem { Label("Speech", systemImage: "speaker.wave.2") }
        }
        .frame(width: DS.Layout.settingsWindowWidth, height: DS.Layout.settingsWindowHeight)
    }
}

private struct AgentsSettingsView: View {
    @AppStorage(AppSettings.Keys.claudeDangerousSkipPermissions)
    private var claudeDangerous: Bool = false

    @AppStorage(AppSettings.Keys.codexDangerousBypass)
    private var codexDangerous: Bool = false

    @AppStorage(AppSettings.Keys.askCommand)
    private var askCommand: String = "claude -p"

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    HStack {
                        Text("Command")
                        Spacer()
                        TextField("claude -p", text: $askCommand)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                    }
                    Text("Used by the Ask overlay (⌘⇧A). The prompt is appended as a single-quoted argument, so e.g. `claude -p`, `codex exec`, or `gemini chat` all work.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Label("Ask", systemImage: "bubble.left.and.bubble.right")
            }

            Section {
                Toggle(isOn: $claudeDangerous) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("Run Claude with --dangerously-skip-permissions")
                        Text("Claude Code will accept every edit and tool call without asking. Equivalent to clicking \"Allow\" on every prompt.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Label("Claude", systemImage: "sparkles")
            }

            Section {
                Toggle(isOn: $codexDangerous) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("Run Codex with --dangerously-bypass-approvals-and-sandbox")
                        Text("OpenAI Codex CLI will skip approvals and run outside the sandbox. Use only inside trusted projects.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Label("Codex", systemImage: "wand.and.stars")
            }

            Section {
                Label("These flags disable safety prompts. Only enable them in projects you trust.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .padding(.top, DS.Space.md)
    }
}

/// Hook installer panel. Two buttons per agent: install / uninstall, with
/// the current state surfaced inline so the user can see whether their
/// `~/.claude/settings.json` (or `~/.codex/hooks.json`) actually has our
/// entries in it. Hooks are an opt-in — first run after upgrade does not
/// auto-install. The watcher itself runs unconditionally; it just sees no
/// status files until hooks are installed.
private struct HooksSettingsView: View {
    /// Re-evaluated whenever the view appears or after a button click so
    /// the row reflects the current on-disk state.
    @State private var states: [AgentHookInstaller.Agent: AgentHookInstaller.InstallState] = [:]
    @State private var lastError: String?

    var body: some View {
        Form {
            Section {
                ForEach(AgentHookInstaller.Agent.allCases) { agent in
                    HookRow(
                        agent: agent,
                        state: states[agent] ?? .notInstalled,
                        onInstall: { perform { try AgentHookInstaller.install(agent) } },
                        onUninstall: { perform { try AgentHookInstaller.uninstall(agent) } }
                    )
                }
            } header: {
                Label("Status hooks", systemImage: "link")
            } footer: {
                Text("Installs a small lifecycle hook in the agent's config (~/.claude/settings.json, ~/.codex/hooks.json). When the agent starts a turn it writes \"working\" to a status file; when it stops it writes \"completed.\" The sidebar dot updates from those files. Only entries marked `# agenticide-hook` are touched — your other hooks are preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let lastError {
                Section {
                    Label(lastError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, DS.Space.md)
        .onAppear { refreshStates() }
    }

    private func refreshStates() {
        for agent in AgentHookInstaller.Agent.allCases {
            states[agent] = AgentHookInstaller.state(for: agent)
        }
    }

    /// Wraps the install/uninstall closure so failures surface in the UI
    /// instead of silently no-op'ing.
    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshStates()
    }
}

private struct HookRow: View {
    let agent: AgentHookInstaller.Agent
    let state: AgentHookInstaller.InstallState
    let onInstall: () -> Void
    let onUninstall: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(agent.displayName)
                    .font(.body.weight(.medium))
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(stateColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.md)
            switch state {
            case .installed:
                Button("Uninstall", role: .destructive, action: onUninstall)
            case .notInstalled:
                Button("Install", action: onInstall)
            case .agentNotInstalled:
                Button("Install", action: onInstall).disabled(true)
            case .configUnreadable:
                Button("Install", action: onInstall).disabled(true)
            }
        }
        .padding(.vertical, DS.Space.xxs)
    }

    private var stateLabel: String {
        switch state {
        case .installed:
            return "Installed at \(agent.configPath)"
        case .notInstalled:
            return "Not installed. Click to write hooks into \(agent.configPath)."
        case .agentNotInstalled:
            return "\(agent.displayName) is not installed (no \((agent.configPath as NSString).deletingLastPathComponent) directory)."
        case .configUnreadable:
            return "\(agent.configPath) exists but isn't valid JSON. Repair or remove it before installing hooks."
        }
    }

    private var stateColor: Color {
        switch state {
        case .installed: return .green
        case .notInstalled: return .secondary
        case .agentNotInstalled, .configUnreadable: return .orange
        }
    }
}

/// Completion-sound preferences. The sound fires when an agent finishes a
/// turn (sidebar status flips Working → Completed/Failed) — driven by the
/// same hook/terminal signals as the sidebar dot, so it works for Claude,
/// Codex, and anything else that flips the status.
private struct NotificationsSettingsView: View {
    @AppStorage(AppSettings.Keys.completionSoundEnabled)
    private var soundEnabled: Bool = false

    @AppStorage(AppSettings.Keys.completionSoundName)
    private var soundName: String = "Glass"

    @AppStorage(AppSettings.Keys.customCompletionSoundPath)
    private var customSoundPath: String = ""

    @State private var importError: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $soundEnabled) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("Play sound when an agent finishes")
                        Text("Fires when a terminal's status flips from Working to Completed — the same signal that drives the sidebar dot.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Picker("Sound", selection: $soundName) {
                    ForEach(CompletionSoundPlayer.systemSoundNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    if !customSoundPath.isEmpty {
                        Divider()
                        Text("Custom — \(customSoundFileName)")
                            .tag(CompletionSoundPlayer.customSoundToken)
                    }
                }

                HStack {
                    Button("Choose Audio File…") { chooseCustomSound() }
                    Spacer()
                    Button("Test") { CompletionSoundPlayer.shared.play() }
                }
            } header: {
                Label("Completion sound", systemImage: "bell")
            } footer: {
                Text("Custom sounds can be any audio file macOS can play (MP3, M4A, WAV, AIFF). The file is copied into AgenticIDE's Application Support folder, so you can move or delete the original afterwards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let importError {
                Section {
                    Label(importError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, DS.Space.md)
    }

    private var customSoundFileName: String {
        (customSoundPath as NSString).lastPathComponent
    }

    private func chooseCustomSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a sound to play when an agent finishes"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            customSoundPath = try CompletionSoundPlayer.importCustomSound(from: url)
            soundName = CompletionSoundPlayer.customSoundToken
            importError = nil
            CompletionSoundPlayer.shared.play()
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct EditorSettingsView: View {
    @AppStorage(AppSettings.Keys.preferredIDE)
    private var preferredIDE: String = ""

    @State private var installed: [ExternalIDE] = []

    var body: some View {
        Form {
            Section {
                Picker("Default editor", selection: $preferredIDE) {
                    if installed.isEmpty {
                        Text("No editors detected").tag("")
                    } else {
                        ForEach(installed) { ide in
                            Label(ide.displayName, systemImage: ide.systemImage)
                                .tag(ide.rawValue)
                        }
                    }
                }
            } header: {
                Label("External editor", systemImage: "curlybraces")
            } footer: {
                Text("Choose which IDE opens when you right-click a project and select \"Open in Editor\". Only editors installed on this Mac are shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(.top, DS.Space.md)
        .onAppear {
            installed = ExternalIDEService.installedIDEs()
            if preferredIDE.isEmpty, let first = installed.first {
                preferredIDE = first.rawValue
            }
        }
    }
}

/// Voice + speed used by the "Speak Selection" command (⇧⌘S). Backed by the
/// system `AVSpeechSynthesizer` — the voice list comes straight from the OS,
/// so any voice the user has downloaded in System Settings → Accessibility →
/// Spoken Content shows up here.
private struct SpeechSettingsView: View {
    @Environment(SystemSpeaker.self) private var speaker

    @AppStorage(AppSettings.Keys.speechVoiceIdentifier)
    private var voiceIdentifier: String = ""

    @AppStorage(AppSettings.Keys.speechRate)
    private var rate: Double = Double(AVSpeechUtteranceDefaultSpeechRate)

    private var voices: [AVSpeechSynthesisVoice] {
        // Sort by language, then name, so the menu groups predictably.
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { lhs, rhs in
                if lhs.language == rhs.language { return lhs.name < rhs.name }
                return lhs.language < rhs.language
            }
    }

    var body: some View {
        Form {
            Section {
                Picker("Voice", selection: $voiceIdentifier) {
                    Text("System default").tag("")
                    Divider()
                    ForEach(voices, id: \.identifier) { voice in
                        Text("\(voice.name) — \(voice.language)").tag(voice.identifier)
                    }
                }

                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Slider(value: $rate,
                           in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate))
                    HStack {
                        Text("Slower").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Speed").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Faster").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Voice", systemImage: "speaker.wave.2")
            } footer: {
                Text("Used when you press ⇧⌘S or click the speaker icon in the tab bar. Selection-only — drag-select the text you want read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Preview voice") {
                        speaker.speak("This is how this voice sounds at the current speed.")
                    }
                    Button("Stop") { speaker.stop() }
                        .disabled(!speaker.isSpeaking)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, DS.Space.md)
    }
}
