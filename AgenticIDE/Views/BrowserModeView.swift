import SwiftUI
import WebKit

/// Full-window browser mode: the owning agent's terminal on the left, its
/// browser pane on the right. Replaces the normal three-pane layout while
/// active (`BrowserManager.isModeActive`); the bottom pager switches between
/// cells that have browsers open.
struct BrowserModeView: View {
    @Environment(SessionManager.self) private var sessions
    @Environment(ProjectStore.self) private var store
    @Environment(LaunchToolStore.self) private var launchTools

    @Bindable var manager: BrowserManager
    /// True while the window is NOT fullscreen: the columns run to the very
    /// top of the window, so the agent column's header starts after the
    /// floating traffic lights. Mirrors the sidebar's behaviour.
    var reserveTrafficLights: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            agentColumn
                .frame(width: 380)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), ignoresSafeAreaEdges: [])
            if let session = manager.focused {
                Divider()
                BrowserColumn(manager: manager, session: session)
                    .id(session.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor), ignoresSafeAreaEdges: [])
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Same top-strip reclaim as the main layout: the headers own the
        // hidden-titlebar strip instead of leaving an empty band above them.
        .ignoresSafeArea(.container, edges: .top)
        // ⌘←/⌘→ page through open browsers here. These post .moveWorkspace,
        // whose normal observer (ProjectWorkspaceView) is unmounted while
        // browser mode is up, so repurposing them is conflict-free.
        .onReceive(NotificationCenter.default.publisher(for: .moveWorkspace)) { note in
            guard let direction = note.object as? Int else { return }
            manager.focusNext(direction)
        }
    }

    // MARK: - Left: the agent driving the browser

    @ViewBuilder
    private var agentColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "terminal")
                    .font(.system(size: DS.Icon.small, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(manager.focused?.ownerTab?.title ?? "No agent attached")
                    .font(DS.Font.control)
                    .lineLimit(1)
                Spacer()
                if let session = manager.focused, let tab = session.ownerTab {
                    BrowserToolbarButton(systemName: "xmark",
                                         help: "Close this agent (the browser stays; launch another)") {
                        closeAgent(session, tab: tab)
                    }
                }
            }
            .padding(.leading, reserveTrafficLights ? DS.Layout.trafficLightInset : 0)
            .padding(.horizontal, DS.Space.sm)
            .frame(height: DS.Control.header)
            .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: [])
            Divider()

            if let tab = manager.focused?.ownerTab {
                GhosttyTerminal(view: tab.view, isActive: true, autoFocus: false)
                    // Keyed like BrowserColumn's .id(session.id): makeNSView only
                    // attaches the tab's NSView once, so paging to another
                    // browser must rebuild the representable or the old agent's
                    // terminal stays on screen.
                    .id(tab.id)
            } else if let session = manager.focused, let cell = session.ownerCell {
                // Bound cell with no program — the same launcher a grid cell
                // shows, launching straight into the bound cell so the new
                // agent inherits this browser.
                CellLauncherView(tools: launchTools.enabledTools) { tool in
                    launch(tool, into: cell)
                }
            } else if let session = manager.focused, session.sourceWorkspace != nil {
                agentPicker(session)
            } else {
                VStack(spacing: DS.Space.md) {
                    Image(systemName: "terminal")
                        .font(.system(size: DS.Icon.large, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("The cell that owned this browser is gone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if manager.sessions.count > 1 {
                Divider()
                pager
            }
        }
    }

    /// Close the bound cell's program with the same code path as the grid's
    /// ✕ button. The browser stays bound to the (now empty) cell and the
    /// launcher takes the left column.
    private func closeAgent(_ session: BrowserSession, tab: TerminalTab) {
        guard let cell = session.ownerCell,
              let located = sessions.locate(cellId: cell.id) else { return }
        located.session.closeCell(cell)
    }

    /// Launch a tool into the browser's bound cell — identical to launching
    /// from the grid, so hints/persistence stay consistent.
    private func launch(_ tool: LaunchTool, into cell: WorkspaceCell) {
        guard let located = sessions.locate(cellId: cell.id),
              let project = store.projects.first(where: { $0.id == located.session.projectId })
        else { return }
        located.workspace.focusedCellId = cell.id
        let launcher = CellLauncher(project: project, session: located.session,
                                    workspace: located.workspace, store: store)
        _ = launcher.launch(tool, into: cell)
    }

    /// User-opened browser with no agent yet. Two ways in: attach one of the
    /// workspace's running cells, or launch a fresh agent into an empty cell
    /// — either way the browser binds to that cell and its agent drives this
    /// pane.
    private func agentPicker(_ session: BrowserSession) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            let workspace = session.sourceWorkspace
            let running = (workspace?.cells ?? [])
                .filter { $0.terminal != nil && manager.session(for: $0) == nil }
            let emptyCell = workspace?.cells.first(where: \.isEmpty)

            if !running.isEmpty {
                Text("Attach a running agent")
                    .font(DS.Font.bodySemibold)
                ForEach(running, id: \.id) { cell in
                    pickerRow(icon: cell.icon, title: cell.terminal?.title ?? "Terminal") {
                        session.attach(to: cell)
                    }
                }
            }

            Text("Launch a new agent")
                .font(DS.Font.bodySemibold)
                .padding(.top, running.isEmpty ? 0 : DS.Space.md)
            if emptyCell != nil {
                ForEach(launchTools.enabledTools.filter { $0.role == .command }) { tool in
                    pickerRow(icon: tool.icon, title: tool.name) {
                        guard let cell = workspace?.cells.first(where: \.isEmpty) else { return }
                        session.attach(to: cell)
                        launch(tool, into: cell)
                    }
                }
            } else {
                Text("The grid is full — close a cell (or enlarge the grid) to launch a new agent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func pickerRow(icon: String?, title: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.sm) {
                quickLaunchIcon(name: icon, size: DS.FontSize.footnote)
                Text(title)
                    .font(DS.Font.body)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, DS.Space.sm)
            .frame(height: DS.Control.large)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pager: some View {
        HStack(spacing: DS.Space.md) {
            Button { manager.focusNext(-1) } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: DS.Icon.small, weight: .semibold))
            }
            .buttonStyle(.plain)
            HStack(spacing: DS.Space.sm) {
                ForEach(manager.sessions) { session in
                    Circle()
                        .fill(session.id == manager.focused?.id
                              ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                        .onTapGesture { manager.focusedId = session.id }
                }
            }
            Button { manager.focusNext(1) } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: DS.Icon.small, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .frame(height: DS.Control.header)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Right side: toolbar (back to grid, URL, reload, picker, close) + web view.
private struct BrowserColumn: View {
    @Environment(SessionManager.self) private var sessions

    @Bindable var manager: BrowserManager
    @Bindable var session: BrowserSession

    /// Local-server URLs scraped from the workspace's terminal screens,
    /// offered on the blank start page. Computed on appear, not per-render.
    @State private var detectedURLs: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if session.urlString.isEmpty {
                startPage
            } else {
                viewportBody
            }
        }
    }

    /// Blank browser: type a URL, or one click on a server the workspace is
    /// already running (scraped from each cell's visible screen text).
    private var startPage: some View {
        VStack(spacing: DS.Space.lg) {
            Image(systemName: "globe")
                .font(.system(size: DS.Icon.display, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Enter a URL above" + (detectedURLs.isEmpty ? "" : ", or open a running server:"))
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(detectedURLs, id: \.self) { url in
                Button {
                    if let parsed = BrowserManager.normalizeURL(url) {
                        session.load(parsed)
                    }
                } label: {
                    Text(url)
                        .font(DS.Font.codeBody)
                        .padding(.horizontal, DS.Space.md)
                        .frame(height: DS.Control.large)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // ignoresSafeAreaEdges: [] — don't expand up into the titlebar
        // safe-area strip over the toolbar (see WorkspaceCellView).
        .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: [])
        .onAppear { detectedURLs = detectServerURLs() }
    }

    /// localhost/loopback URLs visible on any terminal screen in the
    /// browser's workspace (dev servers print them at boot, e.g. vite's
    /// "Local: http://localhost:5174/").
    private func detectServerURLs() -> [String] {
        let workspace = session.sourceWorkspace
            ?? session.ownerCell.flatMap { sessions.locate(cellId: $0.id)?.workspace }
        guard let workspace else { return [] }
        var seen = Set<String>()
        var urls: [String] = []
        for cell in workspace.cells {
            guard let text = cell.terminal?.view.readScreenText() else { continue }
            for match in text.matches(of: /https?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0):\d+[^\s"'<>]*/) {
                let url = String(match.output)
                if seen.insert(url).inserted { urls.append(url) }
            }
        }
        return Array(urls.prefix(5))
    }

    /// Fit fills the card; a device preset renders the page at its logical
    /// resolution and aspect-fits it (WKWebView magnification, capped at 1:1
    /// so devices smaller than the card show at real size, centered).
    /// One subtree for both cases — a branch here would re-parent the
    /// WKWebView on every viewport switch, and a magnification set mid-
    /// reparent gets silently dropped (stale zoom + phantom white space).
    private var viewportBody: some View {
        GeometryReader { geo in
            let size = session.viewport.size
            let scale = size.map { min(geo.size.width / $0.width,
                                       geo.size.height / $0.height, 1) } ?? 1
            WebView(webView: session.webView, zoom: scale)
                .frame(width: size.map { $0.width * scale } ?? geo.size.width,
                       height: size.map { $0.height * scale } ?? geo.size.height)
                .overlay(
                    Rectangle()
                        .strokeBorder(Color(nsColor: .separatorColor),
                                      lineWidth: size == nil ? 0 : 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: [])
    }

    private var toolbar: some View {
        HStack(spacing: DS.Space.sm) {
            Button {
                manager.isModeActive = false
            } label: {
                HStack(spacing: DS.Space.xxs) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: DS.Icon.small, weight: .semibold))
                    Text("Grid")
                        .font(DS.Font.control)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Back to the workspace grid (Esc)")

            Divider().frame(height: 14)

            BrowserToolbarButton(systemName: "chevron.left",
                                 help: "Back",
                                 isEnabled: session.canGoBack) {
                session.goBack()
            }
            BrowserToolbarButton(systemName: "chevron.right",
                                 help: "Forward",
                                 isEnabled: session.canGoForward) {
                session.goForward()
            }

            TextField("URL", text: $session.urlString)
                .textFieldStyle(.roundedBorder)
                .font(DS.Font.footnote)
                .onSubmit {
                    if let url = BrowserManager.normalizeURL(session.urlString) {
                        session.load(url)
                    }
                }

            if session.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Menu {
                Picker("Viewport", selection: $session.viewport) {
                    ForEach(BrowserViewport.allCases) { viewport in
                        Label(viewport.title, systemImage: viewport.symbol)
                            .tag(viewport)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: session.viewport.symbol)
                    .font(.system(size: DS.Icon.small, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: DS.Control.large)
            .help("Emulate a device screen size")

            BrowserToolbarButton(systemName: "arrow.clockwise", help: "Reload") {
                session.webView.reload()
            }
            BrowserToolbarButton(systemName: "cursorarrow.rays",
                                 help: session.pickerActive
                                     ? "Annotate on — click or drag a component, type a note, Enter to send (Esc cancels, ⌘⇧E toggles)"
                                     : "Annotate a component for the agent (click or drag · ⌘⇧E)",
                                 isActive: session.pickerActive) {
                session.pickerActive.toggle()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            BrowserToolbarButton(systemName: "xmark", help: "Close this browser") {
                manager.close(session)
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .frame(height: DS.Control.header)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Small icon button for the browser toolbar (same look as the cell header
/// buttons, which are private to WorkspaceCellView).
private struct BrowserToolbarButton: View {
    let systemName: String
    let help: String
    var isActive: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: DS.Icon.small, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor
                                 : (isEnabled ? Color.primary : Color.secondary.opacity(0.35)))
                .frame(width: DS.Control.compact, height: DS.Control.compact)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(Color.accentColor.opacity(isActive ? 0.18 : 0.0))
                )
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(Color.primary.opacity(isHovered && isEnabled && !isActive ? 0.12 : 0.0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

private struct WebView: NSViewRepresentable {
    let webView: WKWebView
    /// pageZoom, not magnification: pageZoom scales in the web process (like
    /// Safari ⌘+) so content always fills the view — magnification is a
    /// scroll-view canvas transform that letterboxes the page against the
    /// under-page background when a set gets dropped mid-layout.
    var zoom: CGFloat = 1

    func makeNSView(context: Context) -> WKWebView { webView }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if abs(nsView.pageZoom - zoom) > 0.001 {
            nsView.pageZoom = zoom
        }
    }
}

/// Full-height slim panel docked to the trailing window edge while browsers
/// are open but browser mode is collapsed — matches the other pane cards.
/// Click anywhere on it to expand browser mode.
struct BrowserEdgeBar: View {
    let count: Int
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Space.md) {
                Spacer()
                Image(systemName: "chevron.left")
                    .font(.system(size: DS.Icon.small, weight: .semibold))
                Image(systemName: "globe")
                    .font(.system(size: DS.Icon.small, weight: .semibold))
                if count > 1 {
                    Text("\(count)")
                        .font(DS.Font.badge)
                }
                Spacer()
            }
            .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
            .frame(width: 28)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .onHover { hovering = $0 }
        .help("Show agent browser")
    }
}
