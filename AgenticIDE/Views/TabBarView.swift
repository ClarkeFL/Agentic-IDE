import SwiftUI

struct TabBarView: View {
    let project: Project
    let onLaunch: (QuickLaunch) -> Void
    let onSaveQuickLaunch: (QuickLaunch) -> Void
    let onLaunchDefaultShell: () -> Void
    let isSpeaking: Bool
    let onSpeakSelection: () -> Void

    @State private var runServerEditTarget: QuickLaunch?

    var body: some View {
        // Locked to `DS.Control.header` so the tab bar shares its top + bottom
        // edges with the sidebar `PaneHeader` and the inspector header.
        //
        // The launch buttons live inside a horizontal `ScrollView` (so a
        // long quick-launch list doesn't push the speaker off-screen). The
        // speaker, however, must sit outside that scroller — `Spacer` inside
        // a horizontal scroll-view collapses to zero because the scroller
        // sizes to its content, so the only way to right-align the speaker
        // is to anchor it to the outer `HStack` that fills the pane width.
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.sm) {
                        ForEach(project.quickLaunches) { ql in
                            QuickLaunchButton(
                                ql: ql,
                                action: {
                                    if ql.command.isEmpty {
                                        runServerEditTarget = ql
                                    } else {
                                        onLaunch(ql)
                                    }
                                },
                                onEdit: { runServerEditTarget = ql },
                                onReset: {
                                    var reset = ql
                                    reset.command = ""
                                    onSaveQuickLaunch(reset)
                                }
                            )
                            .popover(item: Binding(
                                get: { runServerEditTarget?.id == ql.id ? runServerEditTarget : nil },
                                set: { runServerEditTarget = $0 }
                            )) { target in
                                RunServerPopover(initialCommand: target.command,
                                                 onSave: { newCmd in
                                                     var updated = target
                                                     updated.command = newCmd
                                                     onSaveQuickLaunch(updated)
                                                     runServerEditTarget = nil
                                                 },
                                                 onCancel: { runServerEditTarget = nil })
                            }
                        }

                        InlineIconButton(systemName: "plus",
                                         help: "New shell tab",
                                         action: onLaunchDefaultShell)
                    }
                    .padding(.leading, DS.Space.lg - 2)
                    .padding(.trailing, DS.Space.sm)
                    .frame(height: DS.Control.header)
                }

                Spacer(minLength: 0)

                InlineIconButton(systemName: isSpeaking ? "stop.circle.fill" : "speaker.wave.2",
                                 help: isSpeaking
                                    ? "Stop speaking (⇧⌘.)"
                                    : "Speak selection (⇧⌘S)",
                                 action: onSpeakSelection)
                    .padding(.trailing, DS.Space.lg - 2)
            }
            .frame(height: DS.Control.header)
            Divider()
        }
        .background(.regularMaterial)
    }
}

private struct QuickLaunchButton: View {
    let ql: QuickLaunch
    let action: () -> Void
    var onEdit: (() -> Void)?
    var onReset: (() -> Void)?

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
            HStack(spacing: DS.Space.xs + 1) {
                quickLaunchIcon(name: ql.icon, size: DS.FontSize.body)
                Text(ql.label)
                    .font(DS.Font.bodyMedium)
            }
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
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
        if !ql.command.isEmpty {
            Button("Edit Command…") { onEdit?() }
            Button("Reset Command", role: .destructive) { onReset?() }
            Divider()
        }
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
                .font(DS.Font.bodySemibold)
                .frame(width: DS.Control.standard, height: DS.Control.standard)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
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

