import SwiftUI

struct TabBarView: View {
    let project: Project
    let onLaunch: (QuickLaunch) -> Void
    let onLaunchDefaultShell: () -> Void

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
        .help(ql.command.isEmpty ? "Click to set a command" : ql.command)
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

