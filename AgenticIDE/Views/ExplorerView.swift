import AppKit
import SwiftUI

/// The file-tree + editor "square": one rounded, slightly-inset card. The file
/// tree fills it until a file is opened, at which point the editor appears on
/// the right and a draggable divider splits the card down the middle. Replaces
/// the old separate file-tree (pane ②) and editor (pane ③) panes — the editor
/// now lives inside this card, leaving the workspace pane to take the rest of
/// the window.
struct ExplorerView: View {
    let project: Project
    @Bindable var editor: EditorSession
    @Bindable var gitWatcher: GitStatusWatcher

    @State private var treeWidth: CGFloat
    @State private var dragStart: CGFloat?

    private let treeMin: CGFloat = 180
    private let editorMin: CGFloat = 300
    private static let autosaveKey = "AgenticIDE.ExplorerTreeWidth"

    init(project: Project, editor: EditorSession, gitWatcher: GitStatusWatcher) {
        self.project = project
        self.editor = editor
        self.gitWatcher = gitWatcher
        let saved = UserDefaults.standard.object(forKey: Self.autosaveKey) as? Double
        _treeWidth = State(initialValue: CGFloat(saved ?? 240))
    }

    var body: some View {
        let hasEditor = !editor.tabs.isEmpty
        GeometryReader { geo in
            HStack(spacing: 0) {
                FileTreeView(project: project, editor: editor, gitWatcher: gitWatcher)
                    .frame(width: hasEditor ? clampedTreeWidth(total: geo.size.width) : geo.size.width)
                    .clipped()

                if hasEditor {
                    ExplorerDivider(
                        onDrag: { delta in dragTree(delta: delta, total: geo.size.width) },
                        onEnd: { persist() })

                    EditorPaneView(project: project, editor: editor, gitWatcher: gitWatcher)
                        .frame(maxWidth: .infinity)
                        .clipped()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        // Flush on the divider-facing sides (the divider reserves the gap);
        // a bit of room top, and more at the bottom window edge.
        .padding(EdgeInsets(top: DS.Space.xs, leading: 0,
                            bottom: DS.Space.md, trailing: 0))
    }

    private func clampedTreeWidth(total: CGFloat) -> CGFloat {
        let maxTree = max(treeMin, total - editorMin - ExplorerDivider.width)
        return min(max(treeWidth, treeMin), maxTree)
    }

    private func dragTree(delta: CGFloat, total: CGFloat) {
        let start = dragStart ?? treeWidth
        if dragStart == nil { dragStart = start }
        let maxTree = max(treeMin, total - editorMin - ExplorerDivider.width)
        treeWidth = min(max(start + delta, treeMin), maxTree)
    }

    private func persist() {
        dragStart = nil
        UserDefaults.standard.set(Double(treeWidth), forKey: Self.autosaveKey)
    }
}

/// The draggable seam between the file tree and the editor inside the Explorer
/// card. A thin line in a wider hit area, with a resize cursor on hover.
private struct ExplorerDivider: View {
    static let width: CGFloat = 10
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    @State private var active = false
    @State private var hover = false

    var body: some View {
        Rectangle()
            .fill(hover || active ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor))
            .frame(width: hover || active ? 2 : 1)
            .frame(width: Self.width, alignment: .center)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                hover = hovering
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if !active { active = true }
                        onDrag(value.translation.width)
                    }
                    .onEnded { _ in
                        active = false
                        onEnd()
                    }
            )
    }
}
