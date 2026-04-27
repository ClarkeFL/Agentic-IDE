import SwiftUI

/// App-wide preferences. Reachable via the standard macOS "Settings…" menu
/// item (⌘,). Toggles are bound to `@AppStorage` so they persist across
/// app launches automatically.
struct SettingsView: View {
    var body: some View {
        TabView {
            AgentsSettingsView()
                .tabItem { Label("Agents", systemImage: "sparkles") }
        }
        .frame(width: 520, height: 320)
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
                    VStack(alignment: .leading, spacing: 2) {
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
                    VStack(alignment: .leading, spacing: 2) {
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
        .padding(.top, 8)
    }
}
