import SwiftUI
import WebKit

/// Full-window browser mode: agent column on the left, browser pane on the
/// right. Replaces the normal three-pane layout while active
/// (`BrowserManager.isModeActive`). The left column is multi-cell aware —
/// pick any agent in the workspace, run project servers, and the blank start
/// page actively watches for localhost URLs (including the Servers workspace).
struct BrowserModeView: View {
    @Environment(SessionManager.self) private var sessions
    @Environment(ProjectStore.self) private var store
    @Environment(LaunchToolStore.self) private var launchTools

    @Bindable var manager: BrowserManager
    /// True while the window is NOT fullscreen: the columns run to the very
    /// top of the window, so the agent column's header starts after the
    /// floating traffic lights. Mirrors the sidebar's behaviour.
    var reserveTrafficLights: Bool = true
    /// Called when the user wants out (Grid button / close last pane). Owned
    /// by MainWindow so the mode flag always updates the root layout.
    var onRequestExit: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            agentColumn
                .frame(width: 380)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), ignoresSafeAreaEdges: [])
            if let session = manager.focused {
                Divider()
                BrowserColumn(manager: manager, session: session, onRequestExit: onRequestExit)
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

    // MARK: - Left: agent / launch pad

    @ViewBuilder
    private var agentColumn: some View {
        VStack(spacing: 0) {
            // Header + server strip as a single opaque chrome band so it stays
            // clickable before any page loads (same titlebar issue as right).
            VStack(spacing: 0) {
                agentHeader
                Divider()
                if let session = manager.focused {
                    BrowserServerStrip(session: session,
                                       onRun: { runServers($0, for: session) },
                                       onStop: { stopServer($0, for: session) },
                                       onStopAll: { stopAllServers(for: session) })
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))

            Group {
                if let tab = manager.focused?.ownerTab {
                    GhosttyTerminal(view: tab.view, isActive: true, autoFocus: false)
                        // Keyed like BrowserColumn's .id(session.id): makeNSView only
                        // attaches the tab's NSView once, so paging to another
                        // browser must rebuild the representable or the old agent's
                        // terminal stays on screen.
                        .id(tab.id)
                } else if let session = manager.focused {
                    BrowserLaunchPad(session: session,
                                     launchTools: launchTools.enabledTools,
                                     onAttach: { session.attach(to: $0) },
                                     onLaunch: { tool, cell in
                                         session.attach(to: cell)
                                         launch(tool, into: cell)
                                     },
                                     onRunServers: { runServers($0, for: session) },
                                     onStopServer: { stopServer($0, for: session) },
                                     onStopAllServers: { stopAllServers(for: session) })
                } else {
                    VStack(spacing: DS.Space.md) {
                        Image(systemName: "terminal")
                            .font(.system(size: DS.Icon.large, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No browser session.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if manager.sessions.count > 1 {
                Divider()
                pager
            }

            // Same system CPU/MEM as the sidebar — stay on the browser without
            // bouncing back to the grid to watch load while servers run.
            Divider()
            ResourceBar(layout: .inline)
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, DS.Space.xs)
                .frame(height: DS.Control.header)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var agentHeader: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "terminal")
                .font(.system(size: DS.Icon.small, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(manager.focused?.ownerTab?.title
                 ?? (manager.focused?.ownerCell != nil ? "Empty cell" : "Pick an agent"))
                .font(DS.Font.control)
                .lineLimit(1)
            Spacer()
            if let session = manager.focused {
                // Back to the multi-cell agent list (not a dropdown) so the
                // user can attach any running cell the same way as on open.
                if session.ownerCell != nil {
                    BrowserToolbarButton(systemName: "list.bullet",
                                         help: "Back to agent list — pick a different cell") {
                        session.detachAgent()
                    }
                }
                if let tab = session.ownerTab {
                    BrowserToolbarButton(systemName: "xmark",
                                         help: "Close this agent (the browser stays; pick another)") {
                        closeAgent(session, tab: tab)
                    }
                }
            }
        }
        .padding(.leading, reserveTrafficLights ? DS.Layout.trafficLightInset : 0)
        .padding(.horizontal, DS.Space.sm)
        .frame(height: DS.Control.header)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// Close the bound cell's program with the same code path as the grid's
    /// ✕ button. The browser stays bound to the (now empty) cell and the
    /// launch pad takes the left column.
    private func closeAgent(_ session: BrowserSession, tab: TerminalTab) {
        guard let cell = session.ownerCell,
              let located = sessions.locate(cellId: cell.id) else { return }
        located.session.closeCell(cell)
    }

    /// Launch a tool into a cell — identical to launching from the grid, so
    /// hints/persistence stay consistent.
    private func launch(_ tool: LaunchTool, into cell: WorkspaceCell) {
        guard let located = sessions.locate(cellId: cell.id),
              let project = store.projects.first(where: { $0.id == located.session.projectId })
        else { return }
        located.workspace.focusedCellId = cell.id
        let launcher = CellLauncher(project: project, session: located.session,
                                    workspace: located.workspace, store: store)
        _ = launcher.launch(tool, into: cell)
    }

    private func serverRunner(for session: BrowserSession) -> ServerRunner? {
        guard let projectSession = session.projectSession
                ?? session.ownerCell.flatMap({ sessions.locate(cellId: $0.id)?.session }),
              let project = store.projects.first(where: { $0.id == projectSession.projectId })
        else { return nil }
        return ServerRunner(project: project, session: projectSession, store: store)
    }

    private func runServers(_ servers: [QuickLaunch], for session: BrowserSession) {
        // Don't yank the UI to the Servers workspace — the browser stays up
        // and starts polling their boot URLs.
        serverRunner(for: session)?.run(servers, activate: false)
    }

    private func stopServer(_ label: String, for session: BrowserSession) {
        serverRunner(for: session)?.stop(label)
    }

    private func stopAllServers(for session: BrowserSession) {
        serverRunner(for: session)?.stopAll()
    }

    private func workspaceCells(for session: BrowserSession) -> [WorkspaceCell] {
        if let ws = session.sourceWorkspace { return ws.cells }
        if let cell = session.ownerCell,
           let ws = sessions.locate(cellId: cell.id)?.workspace {
            return ws.cells
        }
        return []
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

// MARK: - Always-visible server run/stop strip

/// Compact chips under the agent header so servers can be started/stopped
/// without leaving the terminal view or the loaded browser page.
private struct BrowserServerStrip: View {
    @Environment(SessionManager.self) private var sessions
    @Environment(ProjectStore.self) private var store

    @Bindable var session: BrowserSession
    let onRun: ([QuickLaunch]) -> Void
    let onStop: (String) -> Void
    let onStopAll: () -> Void

    @State private var showServersEditor = false

    private var projectSession: ProjectSession? {
        session.projectSession
            ?? session.ownerCell.flatMap { sessions.locate(cellId: $0.id)?.session }
    }

    private var project: Project? {
        projectSession.flatMap { ps in store.projects.first(where: { $0.id == ps.projectId }) }
    }

    var body: some View {
        let servers = project?.servers ?? []
        let running: Set<String> = {
            guard let project, let projectSession else { return [] }
            return ServerRunner(project: project, session: projectSession, store: store).runningLabels()
        }()

        HStack(spacing: DS.Space.sm) {
            if servers.isEmpty {
                Button {
                    showServersEditor = true
                } label: {
                    Label("Set up servers", systemImage: "server.rack")
                        .font(DS.Font.control)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.sm) {
                        ForEach(servers) { server in
                            let isRunning = running.contains(server.label)
                            Button {
                                if isRunning { onStop(server.label) }
                                else { onRun([server]) }
                            } label: {
                                HStack(spacing: DS.Space.xs) {
                                    Circle()
                                        .fill(isRunning ? Color.green : Color.secondary.opacity(0.45))
                                        .frame(width: 6, height: 6)
                                    Text(isRunning ? "Stop \(server.label)" : "Run \(server.label)")
                                        .font(DS.Font.control)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, DS.Space.sm)
                                .frame(height: DS.Control.compact)
                                .background(
                                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                        .fill(isRunning
                                              ? Color.red.opacity(0.12)
                                              : Color.primary.opacity(0.06))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(isRunning ? "Stop \(server.label)" : "Start \(server.label)")
                        }
                        if !running.isEmpty {
                            Button {
                                onStopAll()
                            } label: {
                                Text("Stop all")
                                    .font(DS.Font.control)
                                    .foregroundStyle(.red.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Button {
                    showServersEditor = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: DS.Icon.small, weight: .semibold))
                        .frame(width: DS.Control.compact, height: DS.Control.compact)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit servers")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.sm)
        .frame(height: DS.Control.header)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .sheet(isPresented: $showServersEditor) {
            ServersEditor(initial: project?.servers ?? [],
                          onSave: { updated in
                              if let project {
                                  store.updateServers(projectId: project.id, updated)
                              }
                              showServersEditor = false
                          },
                          onCancel: { showServersEditor = false })
        }
    }
}

// MARK: - Launch pad (no agent attached yet)

/// Left-column control surface for a workspace browser: project servers,
/// every cell in the multi-cell grid, and launchers for empty slots.
private struct BrowserLaunchPad: View {
    @Environment(SessionManager.self) private var sessions
    @Environment(ProjectStore.self) private var store

    @Bindable var session: BrowserSession
    let launchTools: [LaunchTool]
    let onAttach: (WorkspaceCell) -> Void
    let onLaunch: (LaunchTool, WorkspaceCell) -> Void
    let onRunServers: ([QuickLaunch]) -> Void
    let onStopServer: (String) -> Void
    let onStopAllServers: () -> Void

    @State private var showServersEditor = false

    private var projectSession: ProjectSession? {
        session.projectSession
            ?? session.ownerCell.flatMap { sessions.locate(cellId: $0.id)?.session }
    }

    private var project: Project? {
        projectSession.flatMap { ps in store.projects.first(where: { $0.id == ps.projectId }) }
    }

    private var workspace: Workspace? {
        session.sourceWorkspace
            ?? session.ownerCell.flatMap { sessions.locate(cellId: $0.id)?.workspace }
    }

    private var runner: ServerRunner? {
        guard let project, let projectSession else { return nil }
        return ServerRunner(project: project, session: projectSession, store: store)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                serversSection
                agentsSection
                launchSection
            }
            .padding(DS.Space.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showServersEditor) {
            ServersEditor(initial: project?.servers ?? [],
                          onSave: { updated in
                              if let project {
                                  store.updateServers(projectId: project.id, updated)
                              }
                              showServersEditor = false
                          },
                          onCancel: { showServersEditor = false })
        }
    }

    // MARK: Servers

    @ViewBuilder
    private var serversSection: some View {
        let servers = project?.servers ?? []
        let running = runner?.runningLabels() ?? []

        sectionTitle("Servers",
                     subtitle: servers.isEmpty
                     ? "Add a named command (e.g. npm run dev) to run in the Servers workspace."
                     : "Start into the Servers workspace. The start page watches for their URLs.")

        if servers.isEmpty {
            Button {
                showServersEditor = true
            } label: {
                Label("Set up servers", systemImage: "server.rack")
                    .font(DS.Font.control)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        } else {
            VStack(spacing: DS.Space.sm) {
                ForEach(servers) { server in
                    let isRunning = running.contains(server.label)
                    HStack(spacing: DS.Space.sm) {
                        Circle()
                            .fill(isRunning ? Color.green : Color.secondary.opacity(0.45))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.label)
                                .font(DS.Font.body)
                                .lineLimit(1)
                            Text(server.command)
                                .font(DS.Font.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button(isRunning ? "Stop" : "Run") {
                            if isRunning { onStopServer(server.label) }
                            else { onRunServers([server]) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(isRunning ? .red : nil)
                    }
                    .padding(.horizontal, DS.Space.sm)
                    .frame(height: DS.Control.large + 8)
                    .background(rowBackground)
                }

                HStack(spacing: DS.Space.md) {
                    if servers.contains(where: { !running.contains($0.label) }) {
                        Button {
                            onRunServers(servers)
                        } label: {
                            Label("Run all stopped", systemImage: "play.fill")
                                .font(DS.Font.control)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                    if !running.isEmpty {
                        Button {
                            onStopAllServers()
                        } label: {
                            Label("Stop all", systemImage: "stop.fill")
                                .font(DS.Font.control)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red.opacity(0.85))
                    }
                    Button {
                        showServersEditor = true
                    } label: {
                        Text("Edit…")
                            .font(DS.Font.control)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Agents

    @ViewBuilder
    private var agentsSection: some View {
        let cells = workspace?.cells ?? []
        sectionTitle("Agents",
                     subtitle: cells.count > 1
                     ? "This workspace has \(cells.count) cells — attach any running agent."
                     : "Attach a running agent so it can drive this browser.")

        if cells.isEmpty {
            Text("No cells in this workspace.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: DS.Space.sm) {
                ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                    let n = index + 1
                    let bound = session.ownerCell?.id == cell.id
                    let hasAgent = cell.terminal != nil
                    Button {
                        onAttach(cell)
                    } label: {
                        HStack(spacing: DS.Space.sm) {
                            Text("#\(n)")
                                .font(DS.Font.footnote)
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .leading)
                            if hasAgent {
                                quickLaunchIcon(name: cell.icon, size: DS.FontSize.footnote)
                            } else {
                                Image(systemName: "square.dashed")
                                    .font(.system(size: DS.Icon.small))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: DS.Control.compact)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(cell.terminal?.title ?? "empty")
                                    .font(DS.Font.body)
                                    .lineLimit(1)
                                if let status = cell.terminal?.status {
                                    Text(statusWord(status))
                                        .font(DS.Font.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if bound {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                                    .font(.system(size: DS.Icon.small))
                            } else if hasAgent {
                                Text("Attach")
                                    .font(DS.Font.control)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, DS.Space.sm)
                        .frame(height: DS.Control.large + 8)
                        .background(rowBackground)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasAgent && !bound)
                    .opacity(hasAgent || bound ? 1 : 0.55)
                }
            }
        }
    }

    // MARK: Launch into empty cell

    @ViewBuilder
    private var launchSection: some View {
        let empty = workspace?.cells.first(where: \.isEmpty)
        let agents = launchTools.filter { $0.role == .command }
        sectionTitle("Launch new agent",
                     subtitle: empty == nil
                     ? "Grid is full — close a cell or enlarge it to launch another agent."
                     : "Starts in the first empty cell and attaches this browser to it.")

        if let empty, !agents.isEmpty {
            VStack(spacing: DS.Space.sm) {
                ForEach(agents) { tool in
                    Button {
                        onLaunch(tool, empty)
                    } label: {
                        HStack(spacing: DS.Space.sm) {
                            quickLaunchIcon(name: tool.icon, size: DS.FontSize.footnote)
                            Text(tool.name)
                                .font(DS.Font.body)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, DS.Space.sm)
                        .frame(height: DS.Control.large)
                        .background(rowBackground)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title)
                .font(DS.Font.bodySemibold)
            Text(subtitle)
                .font(DS.Font.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            .fill(Color.primary.opacity(0.06))
    }

    private func statusWord(_ status: TerminalTabStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .working: return "working"
        case .completed: return "completed"
        case .failed: return "failed"
        }
    }
}

// MARK: - Right: browser column

/// Right side: toolbar (back to grid, URL, reload, picker, close) + web view
/// or the live start page (servers + localhost URL watch).
private struct BrowserColumn: View {
    @Environment(SessionManager.self) private var sessions
    @Environment(ProjectStore.self) private var store

    @Bindable var manager: BrowserManager
    @Bindable var session: BrowserSession
    var onRequestExit: () -> Void = {}

    /// Localhost URLs scraped from every terminal in the project session.
    @State private var detectedURLs: [String] = []
    /// URLs already offered for auto-load this session (avoid reloading the
    /// same chip if the user navigated away).
    @State private var autoLoaded: Set<String> = []
    @State private var showServersEditor = false

    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var projectSession: ProjectSession? {
        session.projectSession
            ?? session.ownerCell.flatMap { sessions.locate(cellId: $0.id)?.session }
    }

    private var project: Project? {
        projectSession.flatMap { ps in store.projects.first(where: { $0.id == ps.projectId }) }
    }

    var body: some View {
        // Content first, chrome via safeAreaInset — keeps the top bar ABOVE
        // the start page / WKWebView in the hit-test order. A plain VStack
        // swap (start page vs webview) left the toolbar unclickable until a
        // page had loaded (non-opaque start-page content + titlebar drag).
        ZStack {
            // Always keep the WKWebView mounted so first-load isn't a layout
            // swap that races the toolbar; hide + ignore hits while blank.
            viewportBody
                .opacity(session.urlString.isEmpty ? 0 : 1)
                .allowsHitTesting(!session.urlString.isEmpty)

            if session.urlString.isEmpty {
                startPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
            }
            // Opaque chrome so AppKit doesn't treat the strip as window-drag.
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onReceive(poll) { _ in
            guard session.urlString.isEmpty else { return }
            refreshDetectedURLs(autoLoad: true)
        }
        .onAppear { refreshDetectedURLs(autoLoad: true) }
        .sheet(isPresented: $showServersEditor) {
            ServersEditor(initial: project?.servers ?? [],
                          onSave: { updated in
                              if let project {
                                  store.updateServers(projectId: project.id, updated)
                              }
                              showServersEditor = false
                          },
                          onCancel: { showServersEditor = false })
        }
    }

    // MARK: Start page

    private var startPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                HStack(spacing: DS.Space.md) {
                    Image(systemName: "globe")
                        .font(.system(size: DS.Icon.display, weight: .light))
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("Workspace browser")
                            .font(DS.Font.bodySemibold)
                        Text("Watching terminals for localhost URLs"
                             + (session.autoLoadDetectedURLs
                                ? " — first hit loads automatically."
                                : "."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("Auto-load", isOn: $session.autoLoadDetectedURLs)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .help("Automatically open the first new localhost URL detected")
                }

                startPageServers
                startPageURLs
            }
            .padding(DS.Space.xxl)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var startPageServers: some View {
        let servers = project?.servers ?? []

        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Text("Project servers")
                    .font(DS.Font.bodySemibold)
                Spacer(minLength: 0)
                if project != nil {
                    Button(servers.isEmpty ? "Set up…" : "Edit…") {
                        showServersEditor = true
                    }
                    .buttonStyle(.plain)
                    .font(DS.Font.control)
                    .foregroundStyle(Color.accentColor)
                }
            }
            if let project, let projectSession {
                let runner = ServerRunner(project: project, session: projectSession, store: store)
                let running = runner.runningLabels()
                if servers.isEmpty {
                    Text("No servers configured yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        showServersEditor = true
                    } label: {
                        Label("Set up servers", systemImage: "server.rack")
                            .font(DS.Font.control)
                            .padding(.horizontal, DS.Space.md)
                            .frame(height: DS.Control.large)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    FlowChips(items: servers.map(\.label)) { label in
                        let isRunning = running.contains(label)
                        Button {
                            if isRunning {
                                runner.stop(label)
                            } else if let server = servers.first(where: { $0.label == label }) {
                                runner.run([server], activate: false)
                                refreshDetectedURLs(autoLoad: true)
                            }
                        } label: {
                            HStack(spacing: DS.Space.xs) {
                                Circle()
                                    .fill(isRunning ? Color.green : Color.secondary.opacity(0.45))
                                    .frame(width: 6, height: 6)
                                Text(isRunning ? "Stop \(label)" : "Run \(label)")
                                    .font(DS.Font.control)
                            }
                            .padding(.horizontal, DS.Space.md)
                            .frame(height: DS.Control.large)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                                    .fill(isRunning
                                          ? Color.red.opacity(0.12)
                                          : Color.primary.opacity(0.06))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(isRunning ? "Stop this server" : "Start this server")
                    }
                    HStack(spacing: DS.Space.md) {
                        if servers.contains(where: { !running.contains($0.label) }) {
                            Button {
                                runner.run(servers, activate: false)
                                refreshDetectedURLs(autoLoad: true)
                            } label: {
                                Label("Run all", systemImage: "play.fill")
                                    .font(DS.Font.control)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                        if !running.isEmpty {
                            Button {
                                runner.stopAll()
                            } label: {
                                Label("Stop all", systemImage: "stop.fill")
                                    .font(DS.Font.control)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red.opacity(0.85))
                        }
                    }
                }
            } else {
                Text("Open the browser from a project workspace to run servers here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var startPageURLs: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Text("Detected localhost URLs")
                    .font(DS.Font.bodySemibold)
                if session.urlString.isEmpty {
                    ProgressView()
                        .controlSize(.mini)
                        .help("Scanning terminal screens every 1.5s")
                }
            }
            if detectedURLs.isEmpty {
                Text("No local URLs yet. Start a server above — or wait for an agent cell to print one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(detectedURLs, id: \.self) { url in
                    Button {
                        if let parsed = BrowserManager.normalizeURL(url) {
                            session.load(parsed)
                        }
                    } label: {
                        Text(url)
                            .font(DS.Font.codeBody)
                            .padding(.horizontal, DS.Space.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
        }
    }

    private func refreshDetectedURLs(autoLoad: Bool) {
        let projectSession = session.projectSession
            ?? session.ownerCell.flatMap { sessions.locate(cellId: $0.id)?.session }
        let urls = LocalServerURLDetector.detect(in: projectSession)
        detectedURLs = urls
        guard autoLoad, session.autoLoadDetectedURLs, session.urlString.isEmpty else { return }
        guard let first = urls.first(where: { !autoLoaded.contains($0) }),
              let parsed = BrowserManager.normalizeURL(first) else { return }
        autoLoaded.insert(first)
        session.load(parsed)
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
            Button(action: onRequestExit) {
                HStack(spacing: DS.Space.xxs) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: DS.Icon.small, weight: .semibold))
                    Text("Grid")
                        .font(DS.Font.control)
                }
                .padding(.horizontal, DS.Space.sm)
                .frame(height: DS.Control.compact)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to the workspace grid (⌘B toggles browser mode)")

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
                                     ? "Annotate on — drag groups peers, ⇧/⌘-click or ⇧-drag adds, Enter sends & exits (Esc clears, ⌘⇧E toggles)"
                                     : "Annotate components for the agent (drag to group · ⇧/⌘-click · ⌘⇧E)",
                                 isActive: session.pickerActive) {
                session.pickerActive.toggle()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            BrowserToolbarButton(systemName: "xmark", help: "Close this browser") {
                manager.close(session)
                if manager.sessions.isEmpty {
                    onRequestExit()
                }
            }
        }
        .padding(.horizontal, DS.Space.sm)
        .frame(height: DS.Control.header)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - Shared bits

/// Horizontal wrapping chip row without a heavy layout dependency.
private struct FlowChips<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        // Simple non-wrapping HStack is enough for a handful of servers;
        // wraps via ScrollView horizontally if many.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.sm) {
                ForEach(items, id: \.self) { item in
                    content(item)
                }
            }
        }
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
