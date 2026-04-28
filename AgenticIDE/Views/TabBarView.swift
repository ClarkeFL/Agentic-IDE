import SwiftUI

struct TabBarView: View {
    let project: Project
    let onLaunch: (QuickLaunch) -> Void
    let onLaunchDefaultShell: () -> Void
    let isSpeaking: Bool
    let onSpeakSelection: () -> Void

    @State private var runServerEditTarget: QuickLaunch?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(project.quickLaunches) { ql in
                    QuickLaunchButton(ql: ql) {
                        if ql.command.isEmpty {
                            runServerEditTarget = ql
                        } else {
                            onLaunch(ql)
                        }
                    }
                    .popover(item: Binding(
                        get: { runServerEditTarget?.id == ql.id ? runServerEditTarget : nil },
                        set: { runServerEditTarget = $0 }
                    )) { target in
                        RunServerPopover(initialCommand: target.command,
                                         onSave: { newCmd in
                                             var updated = target
                                             updated.command = newCmd
                                             onLaunch(updated)
                                             runServerEditTarget = nil
                                         },
                                         onCancel: { runServerEditTarget = nil })
                    }
                }

                InlineIconButton(systemName: "plus",
                                 help: "New shell tab",
                                 action: onLaunchDefaultShell)

                Spacer(minLength: 0)

                InlineIconButton(systemName: isSpeaking ? "stop.circle.fill" : "speaker.wave.2",
                                 help: isSpeaking
                                    ? "Stop speaking (⇧⌘.)"
                                    : "Speak selection (⇧⌘S)",
                                 action: onSpeakSelection)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.regularMaterial)
    }
}

private struct QuickLaunchButton: View {
    let ql: QuickLaunch
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    @AppStorage(AppSettings.Keys.claudeDangerousSkipPermissions)
    private var claudeDangerous: Bool = false

    @AppStorage(AppSettings.Keys.codexDangerousBypass)
    private var codexDangerous: Bool = false

    private var commandExecutable: String {
        let trimmed = ql.command.trimmingCharacters(in: .whitespaces)
        guard let token = trimmed.split(separator: " ", maxSplits: 1).first else { return "" }
        return (String(token) as NSString).lastPathComponent
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                quickLaunchIcon(name: ql.icon, size: 12)
                Text(ql.label)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isPressed ? 0.14 : (isHovered ? 0.08 : 0.0)))
            )
            .contentShape(Rectangle())
            .scaleEffect(isPressed ? 0.97 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .help(helpText)
        .contextMenu { contextMenuContents }
    }

    private var helpText: String {
        if ql.command.isEmpty { return "Click to set a command" }
        switch commandExecutable {
        case "claude" where claudeDangerous:
            return ql.command + " --dangerously-skip-permissions"
        case "codex" where codexDangerous:
            return ql.command + " --dangerously-bypass-approvals-and-sandbox"
        default:
            return ql.command
        }
    }

    @ViewBuilder
    private var contextMenuContents: some View {
        switch commandExecutable {
        case "claude":
            Toggle("Run with --dangerously-skip-permissions", isOn: $claudeDangerous)
            Divider()
            Text("Applies app-wide. Change in Settings…")
                .font(.caption)
        case "codex":
            Toggle("Run with --dangerously-bypass-approvals-and-sandbox", isOn: $codexDangerous)
            Divider()
            Text("Applies app-wide. Change in Settings…")
                .font(.caption)
        default:
            EmptyView()
        }
    }
}

private struct InlineIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isPressed ? 0.14 : (isHovered ? 0.08 : 0.0)))
                )
                .contentShape(Rectangle())
                .scaleEffect(isPressed ? 0.95 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .help(help)
    }
}

