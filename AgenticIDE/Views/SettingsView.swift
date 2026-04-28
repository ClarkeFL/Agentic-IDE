import AVFoundation
import SwiftUI

/// App-wide preferences. Reachable via the standard macOS "Settings…" menu
/// item (⌘,). Toggles are bound to `@AppStorage` so they persist across
/// app launches automatically.
struct SettingsView: View {
    var body: some View {
        TabView {
            AgentsSettingsView()
                .tabItem { Label("Agents", systemImage: "sparkles") }
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

    var body: some View {
        Form {
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
