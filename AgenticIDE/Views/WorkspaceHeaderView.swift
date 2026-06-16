import SwiftUI

/// Pane ④ header strip. Locked to `DS.Control.header` so it shares its top +
/// bottom edges with the sidebar `PaneHeader` and the file-tree header. Shows
/// the active workspace name, the grid-size picker, and the prompt-library +
/// speaker controls (which used to live in the now-removed tab bar).
struct WorkspaceHeaderView: View {
    @Bindable var session: ProjectSession
    @Bindable var workspace: Workspace
    let isSpeaking: Bool
    let onSpeak: () -> Void

    @State private var showGridPicker = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                Text(workspace.name)
                    .font(DS.Font.bodySemibold)
                    .lineLimit(1)
                    .truncationMode(.middle)

                gridButton

                Spacer(minLength: DS.Space.sm)

                PromptLibraryMenu()
                    .padding(.trailing, DS.Space.xs)

                HeaderButton(systemName: isSpeaking ? "stop.circle.fill" : "speaker.wave.2",
                             help: isSpeaking ? "Stop speaking (⇧⌘.)" : "Speak selection (⇧⌘S)",
                             action: onSpeak)
            }
            .padding(.leading, DS.Space.lg - 2)
            .padding(.trailing, DS.Space.lg - 2)
            .frame(height: DS.Control.header)
            Divider()
        }
        .background(.regularMaterial)
    }

    private var gridButton: some View {
        Button { showGridPicker = true } label: {
            HStack(spacing: 3) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: DS.Icon.small, weight: .semibold))
                Text("\(workspace.rows)×\(workspace.cols)")
                    .font(DS.Font.control)
                    .monospacedDigit()
            }
            .padding(.horizontal, DS.Space.sm)
            .frame(height: DS.Control.standard)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose grid size (up to \(Workspace.maxRows)×\(Workspace.maxCols))")
        .popover(isPresented: $showGridPicker, arrowEdge: .bottom) {
            GridSizePicker(current: (workspace.rows, workspace.cols)) { r, c in
                session.resizeWorkspace(workspace, rows: r, cols: c)
                showGridPicker = false
            }
        }
    }
}

private struct HeaderButton: View {
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
