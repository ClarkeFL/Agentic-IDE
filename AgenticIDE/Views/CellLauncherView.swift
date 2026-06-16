import SwiftUI

/// Shown inside an empty workspace cell: a tile per enabled `LaunchTool`.
/// Tapping one spawns that program in the cell (the parent `WorkspaceCellView`
/// owns the spawn). The set of tiles is driven by the global `LaunchToolStore`,
/// so toggling / adding tools in Settings grows or shrinks this grid.
struct CellLauncherView: View {
    let tools: [LaunchTool]
    let onLaunch: (LaunchTool) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: DS.Space.sm),
        GridItem(.flexible(), spacing: DS.Space.sm)
    ]

    var body: some View {
        Group {
            if tools.isEmpty {
                Text("No launchers enabled.\nAdd or enable one in Settings → Launchers.")
                    .font(DS.Font.control)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                LazyVGrid(columns: columns, spacing: DS.Space.sm) {
                    ForEach(tools) { tool in
                        LauncherTile(tool: tool, action: { onLaunch(tool) })
                    }
                }
                .frame(maxWidth: 260)
            }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LauncherTile: View {
    let tool: LaunchTool
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Space.xs + 1) {
                quickLaunchIcon(name: tool.icon, size: 20)
                Text(tool.name)
                    .font(DS.Font.bodyMedium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Space.md)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .fill(Color.primary.opacity(isPressed ? 0.14 : (isHovered ? 0.08 : 0.04)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.18 : 0.08), lineWidth: 0.5)
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
        .help("Run \(tool.name) in this cell")
    }
}
