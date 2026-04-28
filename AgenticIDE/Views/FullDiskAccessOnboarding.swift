import SwiftUI

/// First-launch (and post-rebuild) onboarding for Full Disk Access.
///
/// Two phases, swapped in place:
///   * **Pitch** — explains the cascade-of-prompts problem. Buttons:
///     `Open System Settings`, `Skip`.
///   * **Waiting** — once the user has clicked Open Settings, the gate
///     starts polling. The CTA changes to `Restart AgenticIDE`, enabled
///     only after the gate flips to `.granted`. Restart relaunches the
///     bundle so the new TCC grant takes effect for AgenticIDE and its
///     spawned PTY children.
struct FullDiskAccessOnboarding: View {
    let gate: FullDiskAccessGate
    @Binding var isPresented: Bool

    @State private var didOpenSettings = false

    var body: some View {
        VStack(spacing: DS.Space.xl) {
            Image(systemName: "lock.shield")
                .font(.system(size: DS.Icon.onboarding, weight: .light))
                .foregroundStyle(.tint)

            Text("Grant Full Disk Access")
                .font(.title2.weight(.semibold))

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: DS.Layout.onboardingTextWidth)

            statusRow

            HStack(spacing: DS.Space.md) {
                if didOpenSettings {
                    Button("Restart AgenticIDE") { gate.relaunch() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(gate.status != .granted)
                    Button("Skip", action: skip)
                } else {
                    Button("Open System Settings", action: openSettings)
                        .keyboardShortcut(.defaultAction)
                    Button("Skip", action: skip)
                }
            }
        }
        .padding(DS.Space.xxxl)
        .frame(width: DS.Layout.onboardingWindowWidth)
        .onDisappear { gate.stopPolling() }
    }

    private var message: String {
        if didOpenSettings {
            return "Find AgenticIDE in the list and turn the toggle on. Once it's enabled, click Restart and we'll relaunch with the new permission."
        }
        return "Without Full Disk Access, macOS prompts every time the agent reads a file in Documents, Downloads, or Desktop — sometimes 10+ times in one session. Granting it once stops the cascade."
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: gate.status == .granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(gate.status == .granted ? .green : .secondary)
            Text(statusLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var statusLabel: String {
        switch gate.status {
        case .granted: return "Permission granted"
        case .denied:  return didOpenSettings ? "Waiting for permission…" : "Not granted"
        case .unknown: return "Checking…"
        }
    }

    private func openSettings() {
        gate.openSystemSettings()
        gate.startPolling()
        didOpenSettings = true
    }

    private func skip() {
        gate.skipForThisBuild()
        gate.stopPolling()
        isPresented = false
    }
}
