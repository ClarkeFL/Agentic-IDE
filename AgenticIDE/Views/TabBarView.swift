import SwiftUI

struct TabBarView: View {
    @Bindable var session: ProjectSession
    let project: Project
    let onLaunch: (QuickLaunch) -> Void
    let onLaunchDefaultShell: () -> Void
    let onCloseTab: (UUID) -> Void
    let onSelectTab: (UUID) -> Void

    @State private var runServerEditTarget: QuickLaunch?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                                                 // The parent owns updating the store + spawning.
                                                 onLaunch(updated)
                                                 runServerEditTarget = nil
                                             },
                                             onCancel: { runServerEditTarget = nil })
                        }
                    }

                    Button(action: onLaunchDefaultShell) {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .help("New shell tab")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }

            if !session.tabs.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(session.tabs) { tab in
                            TabChip(tab: tab,
                                    isActive: session.activeTabId == tab.id,
                                    onSelect: { onSelectTab(tab.id) },
                                    onClose: { onCloseTab(tab.id) })
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
        .background(.regularMaterial)
    }
}

private struct QuickLaunchButton: View {
    let ql: QuickLaunch
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = ql.icon {
                    Image(systemName: icon)
                }
                Text(ql.label)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .help(ql.command.isEmpty ? "Click to set a command" : ql.command)
    }
}

private struct TabChip: View {
    let tab: TerminalTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                Text(tab.title)
                    .lineLimit(1)
                    .padding(.leading, 10)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }
}
