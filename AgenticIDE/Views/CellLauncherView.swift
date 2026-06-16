import SwiftUI

/// Shown inside an empty workspace cell: four launch tiles. Tapping one spawns
/// that program in the cell (the parent `WorkspaceCellView` owns the spawn).
struct CellLauncherView: View {
    let onLaunch: (WorkspaceCellKind) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: DS.Space.sm),
        GridItem(.flexible(), spacing: DS.Space.sm)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: DS.Space.sm) {
            ForEach(WorkspaceCellKind.allCases, id: \.self) { kind in
                LauncherTile(kind: kind, action: { onLaunch(kind) })
            }
        }
        .frame(maxWidth: 260)
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LauncherTile: View {
    let kind: WorkspaceCellKind
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Space.xs + 1) {
                quickLaunchIcon(name: kind.icon, size: 20)
                Text(kind.label)
                    .font(DS.Font.bodyMedium)
                    .foregroundStyle(.primary)
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
        .help("Run \(kind.label) in this cell")
    }
}
