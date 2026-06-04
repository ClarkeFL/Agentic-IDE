import AppKit
import SwiftUI

/// Pane-2 alternate body. Shown when the Files/Changes toggle in the file-tree
/// header is flipped to "Changes". Lists every working-tree change reported by
/// `GitStatusWatcher`, grouped by directory, with a status letter on the right
/// and a click-to-open route into the editor (which already handles the diff).
struct ChangesListView: View {
    let project: Project
    @Bindable var editor: EditorSession
    @Bindable var gitWatcher: GitStatusWatcher

    var body: some View {
        Group {
            if !gitWatcher.isGitRepo {
                centered("Not a git repository", systemImage: "questionmark.folder")
            } else if gitWatcher.changes.isEmpty {
                centered("No changes", systemImage: "checkmark.seal")
            } else {
                changesList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grouped: [(dir: String, changes: [GitChange])] {
        // GitService already sorts by directory then filename, so a single
        // pass produces stable groups without re-sorting.
        var out: [(String, [GitChange])] = []
        for change in gitWatcher.changes {
            if let last = out.last, last.0 == change.directoryName {
                out[out.count - 1].1.append(change)
            } else {
                out.append((change.directoryName, [change]))
            }
        }
        return out
    }

    private var changesList: some View {
        List(selection: Binding(
            get: { editor.activeTab?.url },
            set: { url in if let url { editor.open(url) } }
        )) {
            ForEach(grouped, id: \.dir) { group in
                if !group.dir.isEmpty {
                    Text(group.dir)
                        .font(DS.Font.sectionCaps)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .listRowInsets(EdgeInsets(top: DS.Space.xs,
                                                  leading: DS.Gutter.inspector,
                                                  bottom: 1,
                                                  trailing: DS.Gutter.inspectorTrailing))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(group.changes) { change in
                    ChangesRow(change: change) {
                        editor.open(change.url)
                    }
                    .tag(change.url)
                    .listRowInsets(EdgeInsets(top: 1,
                                              leading: DS.Gutter.inspector,
                                              bottom: 1,
                                              trailing: DS.Gutter.inspectorTrailing))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .padding(.top, DS.Space.xs)
    }

    private func centered(_ text: String, systemImage: String) -> some View {
        VStack(spacing: DS.Space.sm) {
            Image(systemName: systemImage)
                .font(.system(size: DS.Icon.large, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct ChangesRow: View {
    let change: GitChange
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "doc")
                .font(DS.Font.footnote)
                .foregroundStyle(change.status.tint)
                .frame(width: DS.Tree.iconColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(change.displayName)
                    .font(DS.Font.body)
                    .foregroundStyle(change.status.tint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: DS.Space.xs)
            if change.additions != 0 || change.deletions != 0 {
                Text("+\(change.additions) −\(change.deletions)")
                    .font(DS.Font.stats)
                    .foregroundStyle(.secondary)
            }
            Text(change.status.indicator)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(change.status.tint)
                .padding(.trailing, 2)
        }
        .padding(.vertical, DS.Space.xs)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpen)
        .help("\(change.relativePath)\n\(change.stateSubtitle)")
    }
}

// MARK: - Footer

/// Pinned to the bottom of pane 2. Shows the current branch + ahead/behind
/// pill, plus four icon buttons (fetch / pull / push / commit). Buttons
/// dim when there's nothing to do; commit pops an NSAlert for the message
/// and stages everything before invoking `git commit`.
struct GitFooterBar: View {
    let project: Project
    @Bindable var gitWatcher: GitStatusWatcher

    /// Reflects an in-flight git action so we can disable the row + spin
    /// the corresponding glyph. Only one action runs at a time.
    @State private var busy: Action?

    private enum Action: Equatable { case fetch, pull, push, commit }

    var body: some View {
        if gitWatcher.isGitRepo {
            HStack(spacing: DS.Space.sm) {
                branchLabel
                Spacer(minLength: 0)
                actionButton(.fetch,
                             systemName: "arrow.triangle.2.circlepath",
                             title: "Fetch",
                             subtitle: gitWatcher.hasUpstream
                                 ? "Refresh ahead/behind from origin without merging."
                                 : "No upstream configured — set one with `git push -u`.",
                             enabled: gitWatcher.hasUpstream,
                             badge: nil)
                actionButton(.pull,
                             systemName: "arrow.down.to.line",
                             title: "Pull",
                             subtitle: gitWatcher.behind > 0
                                 ? "Fast-forward \(gitWatcher.behind) incoming commit\(gitWatcher.behind == 1 ? "" : "s") from origin."
                                 : (gitWatcher.hasUpstream
                                     ? "Branch is up to date with origin."
                                     : "No upstream configured."),
                             enabled: gitWatcher.hasUpstream && gitWatcher.behind > 0,
                             badge: gitWatcher.behind > 0 ? gitWatcher.behind : nil)
                actionButton(.push,
                             systemName: "arrow.up.to.line",
                             title: "Push",
                             subtitle: gitWatcher.ahead > 0
                                 ? "Push \(gitWatcher.ahead) local commit\(gitWatcher.ahead == 1 ? "" : "s") to origin."
                                 : (gitWatcher.hasUpstream
                                     ? "Nothing to push — origin matches HEAD."
                                     : "No upstream configured."),
                             enabled: gitWatcher.hasUpstream && gitWatcher.ahead > 0,
                             badge: gitWatcher.ahead > 0 ? gitWatcher.ahead : nil)
                actionButton(.commit,
                             systemName: "checkmark.circle",
                             title: "Commit",
                             subtitle: gitWatcher.changes.isEmpty
                                 ? "Working tree is clean."
                                 : "Stage all and commit (\(gitWatcher.changes.count) file\(gitWatcher.changes.count == 1 ? "" : "s")).",
                             enabled: !gitWatcher.changes.isEmpty,
                             badge: gitWatcher.changes.isEmpty ? nil : gitWatcher.changes.count)
            }
            .padding(.horizontal, DS.Space.sm)
            .frame(height: 34)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var branchLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(gitWatcher.branch ?? "—")
                .font(DS.Font.control)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let pullRequest = gitWatcher.pullRequest {
                pullRequestBadge(pullRequest)
            }
            if !gitWatcher.hasUpstream && gitWatcher.branch != nil {
                Text("· no upstream")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .help(statusTooltip)
    }

    private func pullRequestBadge(_ pullRequest: GitService.PullRequestInfo) -> some View {
        let amber = Color(red: 0.92, green: 0.68, blue: 0.20)
        return Button {
            if let url = pullRequest.url {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 9, weight: .semibold))
                Text("#\(pullRequest.number)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(amber)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(
                Capsule(style: .continuous)
                    .fill(amber.opacity(0.16))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(amber.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(pullRequest.url == nil)
        .hoverInfo(title: "Pull Request #\(pullRequest.number)",
                   subtitle: pullRequest.title)
    }

    private var statusTooltip: String {
        guard let branch = gitWatcher.branch else { return "Not a git repository" }
        if let pullRequest = gitWatcher.pullRequest {
            return "\(branch) — PR #\(pullRequest.number): \(pullRequest.title)"
        }
        if !gitWatcher.hasUpstream { return "\(branch) — no upstream configured" }
        switch (gitWatcher.ahead, gitWatcher.behind) {
        case (0, 0): return "\(branch) — up to date"
        case (let a, 0): return "\(branch) — \(a) commit\(a == 1 ? "" : "s") to push"
        case (0, let b): return "\(branch) — \(b) commit\(b == 1 ? "" : "s") to pull"
        case (let a, let b): return "\(branch) — diverged: \(a) ahead, \(b) behind"
        }
    }

    @ViewBuilder
    private func actionButton(_ action: Action,
                              systemName: String,
                              title: String,
                              subtitle: String,
                              enabled: Bool,
                              badge: Int?) -> some View {
        FooterActionButton(
            systemName: systemName,
            title: title,
            subtitle: subtitle,
            badge: badge,
            isBusy: busy == action,
            enabled: enabled && busy == nil
        ) {
            switch action {
            case .fetch: Task { await runAction(action) }
            case .pull: Task { await runAction(action) }
            case .push: Task { await runAction(action) }
            case .commit: promptCommit()
            }
        }
    }

    @MainActor
    private func runAction(_ action: Action, message: String? = nil) async {
        busy = action
        defer {
            busy = nil
            // Refresh once on completion so the footer + tree update without
            // waiting for the next 4s poll cycle.
            Task { await gitWatcher.refresh() }
        }
        let result: (ok: Bool, output: String)
        switch action {
        case .fetch:  result = await GitService.fetch(at: project.path)
        case .pull:   result = await GitService.pull(at: project.path)
        case .push:   result = await GitService.push(at: project.path)
        case .commit:
            guard let msg = message else { return }
            result = await GitService.commitAll(at: project.path, message: msg)
        }
        if !result.ok {
            showAlert(title: "git \(actionVerb(action)) failed",
                      detail: result.output.isEmpty ? "git exited non-zero." : result.output)
        }
    }

    private func actionVerb(_ action: Action) -> String {
        switch action {
        case .fetch:  return "fetch"
        case .pull:   return "pull"
        case .push:   return "push"
        case .commit: return "commit"
        }
    }

    /// NSAlert with an editable message field. Auto-stages everything and
    /// runs `git commit -m <msg>` on confirm.
    private func promptCommit() {
        let alert = NSAlert()
        alert.messageText = "Commit changes"
        alert.informativeText = "All changes will be staged and committed on \(gitWatcher.branch ?? "this branch")."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "Commit message"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        Task { await runAction(.commit, message: raw) }
    }

    private func showAlert(title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Footer action button: icon-only, slightly larger than the file-tree
/// header buttons, with a corner numeric badge and a custom hover popup
/// (titled "Fetch / Pull / Push / Commit" plus a one-line description).
/// The popup shows immediately on hover instead of waiting for AppKit's
/// ~2s tooltip delay so the four git verbs are discoverable on first
/// pass without the user having to dwell.
private struct FooterActionButton: View {
    let systemName: String
    let title: String
    let subtitle: String
    let badge: Int?
    let isBusy: Bool
    let enabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    private let buttonWidth: CGFloat = 30
    private let buttonHeight: CGFloat = 26

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if isBusy {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: systemName)
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .frame(width: buttonWidth, height: buttonHeight)
                .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(Color.primary.opacity(enabled && isHovered ? 0.10 : 0.0))
                )

                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 13)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 4, y: -3)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { isHovered = $0 }
        .hoverInfo(title: title, subtitle: subtitle)
    }
}

/// Floating info card rendered inside an `.popover`. The popover hosts
/// itself in its own window, so this card just needs a clean fixed-width
/// layout — no shadow / border (the popover chrome supplies those).
struct HoverInfoCard: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 240, alignment: .leading)
    }
}

/// Reusable view modifier: shows a `HoverInfoCard` in a native popover
/// after a 250ms hover delay. Native popovers render in their own window
/// so the card escapes any pane-level clipping. Pass in title + subtitle
/// at the call site; the modifier owns the show/hide state internally.
extension View {
    func hoverInfo(title: String, subtitle: String) -> some View {
        modifier(HoverInfoModifier(title: title, subtitle: subtitle))
    }
}

private struct HoverInfoModifier: ViewModifier {
    let title: String
    let subtitle: String

    @State private var showPopup = false
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        if !Task.isCancelled {
                            await MainActor.run { showPopup = true }
                        }
                    }
                } else {
                    showPopup = false
                }
            }
            .help("\(title) — \(subtitle)")
            .popover(isPresented: $showPopup,
                     attachmentAnchor: .point(.top),
                     arrowEdge: .bottom) {
                HoverInfoCard(title: title, subtitle: subtitle)
            }
    }
}
