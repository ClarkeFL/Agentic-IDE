import AppKit
import SwiftUI

/// Pane ⑤: a per-project scratchpad bound to `<project>/notes.md`. Reuses the
/// source editor (`CodeEditor`) for editing and the chat markdown renderer
/// (`AskMarkdownView`) for the rendered preview, so headings, tables, code
/// fences etc. all come for free. The file is created (seeded with a short
/// rule for AI agents) the first time the pane is opened for a project.
///
/// Autosaves on a short debounce — it's a notes pad, not a code file, so there
/// is no explicit Save / dirty-tab ceremony.
struct NotesPanel: View {
    let project: Project
    /// Invoked by the header's close button (the ⌘⇧N toggle also drives this
    /// from `MainWindow`).
    let onClose: () -> Void

    @State private var tab: EditorTab?
    @State private var showingPreview = false
    @State private var loadError: String?
    @State private var saveTask: Task<Void, Never>?

    /// Seed written when `notes.md` doesn't exist yet — just a heading and a
    /// prompt so it's obvious where to start typing.
    private static let seed = """
    # Project notes

    Write your notes below.


    """

    private var notesURL: URL {
        project.path.appendingPathComponent("notes.md")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Same floating-card chrome as the explorer + workspace panes. Rightmost
        // pane, so the window-edge margin is on the trailing side; flush (0)
        // against the divider on the leading side.
        .paneCard(fill: Color(nsColor: .textBackgroundColor),
                  insets: EdgeInsets(top: DS.Space.xs, leading: 0,
                                     bottom: DS.Space.md, trailing: DS.Space.md))
        .task(id: project.id) { load() }
        .onDisappear { flush() }
    }

    // MARK: - Header

    private var header: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .frame(maxWidth: .infinity, alignment: .bottom)

            HStack(spacing: DS.Space.sm) {
                Image(systemName: "note.text")
                    .font(DS.Font.bodySemibold)
                    .foregroundStyle(.secondary)
                Text("Notes")
                    .font(DS.Font.bodySemibold)
                    .lineLimit(1)

                Spacer(minLength: DS.Space.sm)

                if tab != nil {
                    pill(title: "Preview", icon: "doc.richtext", isOn: showingPreview) {
                        showingPreview.toggle()
                    }
                }

                NotesIconButton(systemName: "xmark", help: "Close notes (⌘⇧N)", action: onClose)
            }
            .padding(.horizontal, DS.Space.lg - 2)
            .frame(height: DS.Control.header)
        }
        .frame(height: DS.Control.header)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let err = loadError {
            placeholder(systemImage: "exclamationmark.triangle",
                        title: "Couldn't open notes",
                        detail: err)
        } else if let tab {
            if showingPreview {
                ScrollView {
                    AskMarkdownView(text: tab.text)
                        .padding(.horizontal, DS.Space.xl)
                        .padding(.vertical, DS.Space.lg)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeEditor(tab: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: tab.text) { _, _ in scheduleSave() }
            }
        } else {
            VStack(spacing: DS.Space.sm) {
                ProgressView().controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func placeholder(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: DS.Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: DS.Icon.large, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(detail)
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.xxl)
    }

    private func pill(title: String, icon: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : .secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : .primary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOn ? Color.accentColor : Color.primary.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Hide preview (return to editing)" : "Preview the rendered Markdown")
    }

    // MARK: - Load / save

    /// Read `notes.md`, creating it from the seed if it's missing. Tiny file —
    /// safe to read on the main actor.
    private func load() {
        let url = notesURL
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data(Self.seed.utf8).write(to: url, options: .atomic)
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            let t = EditorTab(url: url)
            t.text = text
            t.savedText = text
            t.didLoad = true
            tab = t
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Debounced write — coalesces bursts of typing into one disk write.
    /// ponytail: fixed 600ms debounce, fine for a notes pad; revisit only if
    /// notes grow large enough that atomic writes stutter.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            write()
        }
    }

    /// Cancel any pending debounce and write immediately (on close / teardown).
    private func flush() {
        saveTask?.cancel()
        write()
    }

    private func write() {
        guard let tab, tab.text != tab.savedText else { return }
        do {
            try Data(tab.text.utf8).write(to: tab.url, options: .atomic)
            tab.savedText = tab.text
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// Square hover-highlight icon button matching the workspace header's buttons.
private struct NotesIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(DS.Font.bodySemibold)
                .frame(width: DS.Control.standard, height: DS.Control.standard)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.08 : 0.0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
