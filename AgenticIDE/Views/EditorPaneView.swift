import AppKit
import SwiftUI

/// Pane 3 of the four-pane layout. Renders the editor tab bar across the top
/// and the active tab's `CodeEditor` underneath. Empty / loading / binary /
/// load-error states each get a placeholder. Save is wired via the global
/// `.saveActiveEditorTab` notification (posted by File → Save / ⌘S).
struct EditorPaneView: View {
    let project: Project
    @Bindable var editor: EditorSession
    @Bindable var gitWatcher: GitStatusWatcher

    var body: some View {
        VStack(spacing: 0) {
            EditorTabBar(editor: editor,
                         gitWatcher: gitWatcher,
                         onToggleDiff: toggleDiff,
                         onOpenInBrowser: openActiveInBrowser)
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .saveActiveEditorTab)) { _ in
            saveActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeActiveEditorTab)) { _ in
            closeActive()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let tab = editor.activeTab {
            ZStack {
                if let err = tab.loadError {
                    placeholder(systemImage: "exclamationmark.triangle",
                                title: "Couldn't open this file",
                                detail: err)
                } else if tab.isBinary {
                    placeholder(systemImage: "doc.zipper",
                                title: "Binary file",
                                detail: "This file isn't UTF-8 text — open it externally to edit.")
                } else if !tab.didLoad {
                    VStack(spacing: DS.Space.sm) {
                        ProgressView().controlSize(.small)
                        Text("Loading \(tab.displayName)…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tab.showingDiff {
                    unifiedDiff(tab: tab)
                } else {
                    CodeEditor(tab: tab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            placeholder(systemImage: "doc.text",
                        title: "No file open",
                        detail: "Click a file in the tree to view and edit it.")
        }
    }

    /// Single-pane unified diff. Reads HEAD via `editor.loadHeadIfNeeded`
    /// (cached on the tab once loaded) and feeds it alongside the live
    /// `tab.text` to `UnifiedDiffView`. As the user types, the diff
    /// recomputes in-process — no `git diff` shell-out needed for the
    /// "diff against HEAD" experience.
    @ViewBuilder
    private func unifiedDiff(tab: EditorTab) -> some View {
        if let head = tab.headText {
            UnifiedDiffView(headText: head,
                            workingText: tab.text,
                            fileURL: tab.url)
        } else if tab.headLoadFailed {
            placeholder(systemImage: "doc.text.below.ecg",
                        title: "No HEAD version to compare",
                        detail: "This file isn't tracked in HEAD yet (untracked or new). Save and commit, or close diff mode.")
        } else {
            VStack(spacing: DS.Space.sm) {
                ProgressView().controlSize(.small)
                Text("Loading HEAD version…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                await editor.loadHeadIfNeeded(tab, projectRoot: project.path)
            }
        }
    }

    private func placeholder(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: DS.Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: DS.Icon.large, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.xxl)
    }

    // MARK: - Actions

    private func saveActive() {
        guard let tab = editor.activeTab,
              !tab.isBinary,
              tab.loadError == nil else { return }
        do {
            try editor.save(tab)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save \(tab.displayName)"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func closeActive() {
        guard let tab = editor.activeTab else { return }
        EditorTabBar.requestClose(tab: tab, editor: editor)
    }

    /// Toggle diff mode for the active tab. On the way IN we kick off the
    /// HEAD load (no-op if already cached). On the way OUT we just flip
    /// the flag — the tab's working buffer is unaffected.
    private func toggleDiff() {
        guard let tab = editor.activeTab else { return }
        tab.showingDiff.toggle()
        if tab.showingDiff {
            Task { await editor.loadHeadIfNeeded(tab, projectRoot: project.path) }
        }
    }

    /// Open the active HTML tab in the user's default browser. No-op for
    /// non-HTML tabs — the button that calls this is only shown when the
    /// active tab is HTML, but guarding here keeps callers honest.
    private func openActiveInBrowser() {
        guard let tab = editor.activeTab,
              Self.isHTML(tab.url) else { return }
        NSWorkspace.shared.open(tab.url)
    }

    static func isHTML(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }
}

// MARK: - Tab bar

/// The strip across the top of pane 3. Horizontally scrollable, dirty
/// indicator per tab, hover-revealed close button, right-click context
/// menu. Each tab is its own `Button` so SwiftUI list-diffing keeps stable
/// identity across reorders (we don't reorder today, but cheap insurance).
struct EditorTabBar: View {
    @Bindable var editor: EditorSession
    @Bindable var gitWatcher: GitStatusWatcher
    /// Tapping the diff toggle calls back to the parent so the parent can
    /// kick off the HEAD-content load alongside the state flip — the bar
    /// itself doesn't know about the project root.
    let onToggleDiff: () -> Void
    /// Fires the "Open in Browser" pill that appears for HTML tabs. The bar
    /// otherwise has no business knowing whether a file is HTML.
    let onOpenInBrowser: () -> Void

    /// Active-tab git status (if any). Drives whether the Diff toggle is
    /// shown — there's nothing to compare for clean / untracked-but-clean
    /// files.
    private var activeStatus: GitFileStatus? {
        guard let tab = editor.activeTab else { return nil }
        return gitWatcher.status(for: tab.url)
    }

    /// Whether the active tab is an HTML file — drives whether the Preview
    /// pill is shown in the tab strip.
    private var activeIsHTML: Bool {
        guard let tab = editor.activeTab else { return false }
        return EditorPaneView.isHTML(tab.url)
    }

    var body: some View {
        // ZStack so the bottom-edge border is drawn _behind_ the chips. The
        // active chip paints `.textBackgroundColor` over its slice of that
        // 1pt line, making it look like the active tab seamlessly flows
        // into the editor body below — VS Code's signature trick.
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .frame(maxWidth: .infinity, alignment: .bottom)

            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(editor.tabs) { tab in
                            EditorTabChip(
                                tab: tab,
                                isActive: tab.id == editor.activeTabId,
                                onActivate: { editor.activeTabId = tab.id },
                                onClose: { Self.requestClose(tab: tab, editor: editor) }
                            )
                            .contextMenu {
                                Button("Close") {
                                    Self.requestClose(tab: tab, editor: editor)
                                }
                                Button("Close Other Tabs") {
                                    Self.closeOthers(keep: tab.id, editor: editor)
                                }
                                Button("Close All") {
                                    Self.closeAll(editor: editor)
                                }
                                Divider()
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([tab.url])
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)

                if activeIsHTML {
                    OpenInBrowserButton(action: onOpenInBrowser)
                        .padding(.trailing, DS.Space.xs)
                }

                if let status = activeStatus, status != .deleted {
                    DiffToggleButton(
                        isOn: editor.activeTab?.showingDiff ?? false,
                        statusTint: status.tint,
                        action: onToggleDiff
                    )
                    .padding(.trailing, DS.Space.sm)
                }
            }
            .frame(height: DS.Control.header)
        }
        .frame(height: DS.Control.header)
        // Solid background — `.regularMaterial` is translucent and let
        // editor content (line numbers, scrolled-up rows) blur through
        // into the tab area, looking like the gutter "leaked into the
        // header". The control-background colour matches the system's
        // standard non-content surfaces.
        .background(Color(nsColor: .controlBackgroundColor))
        .zIndex(1)
    }

    /// Close `tab` after asking the user about unsaved changes if any. Posts
    /// straight to the editor session — caller doesn't need to think about
    /// activeTab juggling, the session does that.
    @MainActor
    static func requestClose(tab: EditorTab, editor: EditorSession) {
        if tab.isDirty {
            let alert = NSAlert()
            alert.messageText = "Save changes to \(tab.displayName)?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do {
                    try editor.save(tab)
                } catch {
                    let err = NSAlert()
                    err.messageText = "Couldn't save \(tab.displayName)"
                    err.informativeText = error.localizedDescription
                    err.alertStyle = .warning
                    err.addButton(withTitle: "OK")
                    err.runModal()
                    return
                }
            case .alertSecondButtonReturn:
                break // discard
            default:
                return // cancel
            }
        }
        editor.close(id: tab.id)
    }

    @MainActor
    private static func closeOthers(keep: UUID, editor: EditorSession) {
        let toClose = editor.tabs.filter { $0.id != keep }
        for tab in toClose {
            requestClose(tab: tab, editor: editor)
        }
    }

    @MainActor
    private static func closeAll(editor: EditorSession) {
        for tab in editor.tabs {
            requestClose(tab: tab, editor: editor)
        }
    }
}

/// Compact split-rectangles glyph + word "Diff", shown in the editor tab
/// strip when the active file has a git status. Highlighted when toggled
/// on; tints the icon with the file's status colour so the affordance
/// matches the badge in the file tree.
private struct DiffToggleButton: View {
    let isOn: Bool
    let statusTint: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : statusTint)
                Text("Diff")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : .primary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOn
                          ? Color.accentColor
                          : Color.primary.opacity(isHovered ? 0.10 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isOn ? "Hide diff (return to single editor)"
                   : "Show diff (HEAD vs working copy)")
    }
}

/// Compact "Safari" glyph + "Open", shown in the editor tab strip when the
/// active file is `.html`/`.htm`. Single-tap action — opens the file in the
/// user's default browser via `NSWorkspace.open`. Visually mirrors
/// `DiffToggleButton` so the pills line up consistently when both are
/// visible.
private struct OpenInBrowserButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "safari")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Open in Browser")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.10 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open this file in your default browser")
    }
}

private struct EditorTabChip: View {
    let tab: EditorTab
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var isCloseHovered = false

    /// Show the close X when the tab is hovered, when the close button
    /// itself is hovered (so it doesn't disappear under the cursor), or
    /// always for the active tab. The dirty dot otherwise sits in the same
    /// 14pt slot — they swap, never stack — to keep layout still.
    private var showsClose: Bool { isHovered || isCloseHovered || isActive }

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "doc")
                .font(DS.Font.footnote)
                .foregroundStyle(.secondary)
                .opacity(isActive ? 1 : 0.7)
            Text(tab.displayName)
                .font(DS.Font.body)
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            trailingIndicator
                .frame(width: 14, height: 14)
        }
        .padding(.horizontal, DS.Space.sm)
        .frame(height: DS.Control.header)
        .background(chipBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { isHovered = $0 }
        .help(tab.url.path)
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        // Dirty-vs-close swap. Both are kept rendered at all times (with
        // opacity) so AppKit's hit-testing of the close button doesn't
        // jitter across hover thresholds.
        ZStack {
            Circle()
                .fill(Color.secondary)
                .frame(width: 6, height: 6)
                .opacity(tab.isDirty && !showsClose ? 1 : 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.primary.opacity(isCloseHovered ? 0.14 : 0))
                    )
            }
            .buttonStyle(.plain)
            .opacity(showsClose ? 1 : 0)
            .onHover { isCloseHovered = $0 }
        }
    }

    /// Active tab paints with the editor's text-background colour so it
    /// reads as "this tab IS the editor" — the same trick VS Code uses to
    /// remove the visual gap between the tab strip and the document. The
    /// strip's `.regularMaterial` background continues to show behind the
    /// other tabs.
    @ViewBuilder
    private var chipBackground: some View {
        if isActive {
            Rectangle().fill(Color(nsColor: .textBackgroundColor))
        } else if isHovered {
            Rectangle().fill(Color.primary.opacity(0.05))
        } else {
            Color.clear
        }
    }
}
