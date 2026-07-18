import AppKit
import SwiftUI

/// Pane 2: the project file tree (and Changes list). Always fills this
/// column — the editor no longer lives beside it. Opening a file floats
/// the editor over the workspace grid instead, so this pane keeps a
/// stable tree-only width and the grid never shrinks to make room.
struct ExplorerView: View {
    let project: Project
    @Bindable var editor: EditorSession
    @Bindable var gitWatcher: GitStatusWatcher

    var body: some View {
        FileTreeView(project: project, editor: editor, gitWatcher: gitWatcher)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Surface.app)
    }
}
