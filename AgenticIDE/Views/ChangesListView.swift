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

    /// Drives the branch picker popover. We use a popover (not a `Menu`) so it
    /// opens *upward* — `arrowEdge: .top` — instead of dropping down off the
    /// bottom-pinned footer. SwiftUI `Menu` offers no direction control.
    @State private var showBranchMenu = false

    private enum Action: Equatable { case fetch, pull, push, commit }

    var body: some View {
        if gitWatcher.isGitRepo {
            // Two rows: the action buttons sit on their own line above so a long
            // branch name (e.g. "fabio/intake-work" + PR badge) gets the full
            // width below instead of crowding the buttons onto one line.
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.sm) {
                    actionButtons
                    Spacer(minLength: 0)
                }
                branchLabel
            }
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, DS.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Solid surface that matches the file-tree header/body — the old
            // .regularMaterial let the desktop wallpaper tint bleed through, so
            // the footer read as a different pane than the folder viewer above.
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .top) { Divider() }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
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

    private var branchLabel: some View {
        HStack(spacing: 4) {
            Button {
                showBranchMenu = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(gitWatcher.branch ?? "—")
                        .font(DS.Font.control)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .popover(isPresented: $showBranchMenu, arrowEdge: .top) {
                branchMenuContent
            }
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

    @ViewBuilder
    private var branchMenuContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Switch to")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.xs)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(gitWatcher.localBranches, id: \.self) { name in
                        Button {
                            showBranchMenu = false
                            Task { await switchTo(name) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .opacity(name == gitWatcher.branch ? 1 : 0)
                                Text(name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, DS.Space.xs)
                            .contentShape(Rectangle())
                        }
                        .disabled(name == gitWatcher.branch)
                    }
                }
            }
            .frame(maxHeight: 220)
            Divider()
            Button("New Branch…") {
                showBranchMenu = false
                promptNewBranch()
            }
            .padding(.horizontal, DS.Space.xs)
            let deletable = gitWatcher.localBranches.filter { $0 != gitWatcher.branch }
            if !deletable.isEmpty {
                Menu("Delete Branch") {
                    ForEach(deletable, id: \.self) { name in
                        Button(name, role: .destructive) {
                            showBranchMenu = false
                            promptDeleteBranch(name)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, DS.Space.xs)
            }
        }
        .buttonStyle(.plain)
        .padding(DS.Space.sm)
        .frame(width: 240, alignment: .leading)
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

    @MainActor
    private func switchTo(_ name: String) async {
        let result = await GitService.switchBranch(name, at: project.path)
        if !result.ok {
            showAlert(title: "Switch to \(name) failed",
                      detail: result.output.isEmpty ? "git exited non-zero." : result.output)
        }
        await gitWatcher.refresh()
    }

    /// NSAlert with a name field. Creates a branch off HEAD and switches to it.
    private func promptNewBranch() {
        let alert = NSAlert()
        alert.messageText = "New branch"
        alert.informativeText = "Creates a branch from the current HEAD and switches to it."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "branch-name"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            let result = await GitService.createBranch(name, at: project.path)
            if !result.ok {
                showAlert(title: "Create \(name) failed",
                          detail: result.output.isEmpty ? "git exited non-zero." : result.output)
            }
            await gitWatcher.refresh()
        }
    }

    /// Confirm + delete a local branch. `-d` first; if git refuses an
    /// unmerged branch, offer a force (`-D`) follow-up rather than dead-ending.
    private func promptDeleteBranch(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "Delete branch \"\(name)\"?"
        alert.informativeText = "Removes the local branch. Unmerged commits may be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            var result = await GitService.deleteBranch(name, at: project.path, force: false)
            if !result.ok {
                let force = NSAlert()
                force.messageText = "Branch \"\(name)\" isn't fully merged"
                force.informativeText = result.output.isEmpty
                    ? "Force-delete anyway? Unmerged commits will be lost."
                    : result.output
                force.alertStyle = .warning
                force.addButton(withTitle: "Force Delete")
                force.addButton(withTitle: "Cancel")
                if force.runModal() == .alertFirstButtonReturn {
                    result = await GitService.deleteBranch(name, at: project.path, force: true)
                }
            }
            if !result.ok {
                showAlert(title: "Delete \(name) failed",
                          detail: result.output.isEmpty ? "git exited non-zero." : result.output)
            }
            await gitWatcher.refresh()
        }
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

/// Floating info card hosted in a click-through tooltip window. It owns its
/// own chrome (background / border / shadow comes from the window) so it reads
/// well as a standalone surface, not just inside popover trim.
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
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Reusable view modifier: shows a `HoverInfoCard` in a floating tooltip
/// window after a 250ms hover delay. We deliberately avoid `.popover` because
/// a popover is a transient window that *intercepts the first click* — it
/// would sit over the trigger and swallow the click meant for the button.
/// `TooltipWindowController` uses a non-activating, `ignoresMouseEvents`
/// window instead, so the card floats above any pane clipping yet the control
/// underneath stays fully clickable.
extension View {
    func hoverInfo(title: String, subtitle: String) -> some View {
        modifier(HoverInfoModifier(title: title, subtitle: subtitle))
    }
}

private struct HoverInfoModifier: ViewModifier {
    let title: String
    let subtitle: String

    @State private var hoverTask: Task<Void, Never>?
    @State private var anchor = TooltipAnchor()

    func body(content: Content) -> some View {
        content
            .background(TooltipAnchorReader(anchor: anchor))
            .onHover { hovering in
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        if !Task.isCancelled {
                            await MainActor.run {
                                guard let frame = anchor.screenFrame() else { return }
                                TooltipWindowController.shared.show(
                                    title: title, subtitle: subtitle, anchorScreenFrame: frame)
                            }
                        }
                    }
                } else {
                    TooltipWindowController.shared.hide()
                }
            }
            .help("\(title) — \(subtitle)")
            .onDisappear {
                hoverTask?.cancel()
                TooltipWindowController.shared.hide()
            }
    }
}

/// Holds a weak reference to the trigger's backing `NSView` so the modifier
/// can resolve its current on-screen frame at hover time (positions move as
/// panes resize / scroll).
@MainActor
final class TooltipAnchor {
    weak var view: NSView?

    func screenFrame() -> NSRect? {
        guard let view, let window = view.window else { return nil }
        let inWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }
}

private struct TooltipAnchorReader: NSViewRepresentable {
    let anchor: TooltipAnchor

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        anchor.view = v
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

/// A single shared, borderless, non-activating window that hosts the hover
/// card. `ignoresMouseEvents = true` makes it click-through, so it can sit
/// over the trigger without ever stealing the click — the actual fix for the
/// "tooltip covers the button" bug.
@MainActor
final class TooltipWindowController {
    static let shared = TooltipWindowController()

    private var panel: NSPanel?
    private var host: NSHostingView<HoverInfoCard>?

    func show(title: String, subtitle: String, anchorScreenFrame anchor: NSRect) {
        let card = HoverInfoCard(title: title, subtitle: subtitle)

        let panel: NSPanel
        if let existing = self.panel, let host {
            panel = existing
            host.rootView = card
        } else {
            let host = NSHostingView(rootView: card)
            let p = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .popUpMenu
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.ignoresMouseEvents = true          // <- click-through: the whole point
            p.collectionBehavior = [.transient, .ignoresCycle]
            p.contentView = host
            self.panel = p
            self.host = host
            panel = p
        }

        guard let host = self.host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        // Place the card just below the trigger (screen coords = bottom-left
        // origin, so "below" is a smaller y), horizontally centered on it, and
        // clamp into the visible screen.
        let gap: CGFloat = 6
        var origin = NSPoint(x: anchor.midX - size.width / 2,
                             y: anchor.minY - gap - size.height)

        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }
            ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
            // If it would fall off the bottom, flip above the trigger instead.
            if origin.y < vf.minY + 4 {
                origin.y = anchor.maxY + gap
            }
        }

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
