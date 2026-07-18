import AppKit
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
                .background(DS.Surface.editor, ignoresSafeAreaEdges: [])
            if let session = manager.focused {
                Divider()
                BrowserColumn(manager: manager, session: session, onRequestExit: onRequestExit)
                    .id(session.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.Surface.app, ignoresSafeAreaEdges: [])
            }
        }
        .background(DS.Surface.app)
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
            .background(DS.Surface.app)

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

            // Weekly plan usage (horizontal — the agent column is wider than
            // the project sidebar) + system CPU/MEM, same sources as the
            // left-sidebar footer so you don't leave browser mode to check.
            Divider()
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                UsageBar(layout: .inline)
                ResourceBar(layout: .inline)
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            .background(DS.Surface.app)
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
        .background(DS.Surface.app)
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
            if let name = project?.name {
                Text(name)
                    .font(DS.Font.control)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Servers for project “\(name)”")
            }
            if servers.isEmpty {
                Button {
                    showServersEditor = true
                } label: {
                    Label(project == nil ? "No project bound" : "Set up servers",
                          systemImage: "server.rack")
                        .font(DS.Font.control)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(project == nil)
                .help(project == nil
                      ? "Browser isn’t tied to a project — press ⌘B from a selected project"
                      : "Configure dev servers for this project")
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
        .background(DS.Surface.app)
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
/// grid setup (layout + per-cell agent picks when nothing is running), or
/// attach / fill empty slots once the grid already has agents.
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
    /// Setup wizard when the grid has no running agents yet.
    @State private var setupLayout: GridLayout?
    /// Per-cell tool id for the setup step (`nil` = leave empty).
    @State private var setupPicks: [UUID?] = []
    /// Which cell tile is active in the assign step (chips apply to this one).
    @State private var setupFocusIndex: Int = 0

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

    /// Fresh browser / empty grid — walk the user through layout + agents.
    private var needsSetup: Bool {
        let cells = workspace?.cells ?? []
        return cells.isEmpty || cells.allSatisfy { $0.terminal == nil }
    }

    private var agentTools: [LaunchTool] {
        launchTools.filter { $0.role == .command || $0.role == .terminal }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                serversSection
                if needsSetup {
                    setupSection
                } else {
                    agentsSection
                    launchSection
                }
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

    // MARK: Setup wizard (no agents running yet)

    @ViewBuilder
    private var setupSection: some View {
        if let layout = setupLayout {
            setupAssignAgents(layout: layout)
        } else {
            setupPickLayout
        }
    }

    /// Matches `LayoutChooserView.gridLayoutStep` — centered title + card row.
    private var setupPickLayout: some View {
        VStack(spacing: DS.Space.lg) {
            VStack(spacing: DS.Space.xs) {
                Text("Choose a layout")
                    .font(.title3.weight(.semibold))
                Text("Then assign an agent to each cell.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            // Same card language as the main grid chooser (glyph + title).
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 100), spacing: DS.Space.sm)],
                spacing: DS.Space.sm
            ) {
                ForEach(Array(GridLayout.quickPresets.enumerated()), id: \.offset) { _, preset in
                    Button {
                        chooseLayout(preset.layout)
                    } label: {
                        VStack(spacing: DS.Space.md) {
                            LayoutGlyph(layout: preset.layout, square: 14, gap: 4) { _, _ in
                                Color.accentColor.opacity(0.85)
                            }
                            .frame(height: 40)
                            Text(preset.title)
                                .font(DS.Font.bodySemibold)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .padding(.horizontal, DS.Space.xs)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(preset.title)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DS.Space.sm)
    }

    /// Centered mini-grid of cells (real layout shape) + agent chip palette.
    private func setupAssignAgents(layout: GridLayout) -> some View {
        let focus = min(setupFocusIndex, max(0, layout.cellCount - 1))
        let pick = setupPicks.indices.contains(focus) ? setupPicks[focus] : nil

        return VStack(spacing: DS.Space.lg) {
            VStack(spacing: DS.Space.xs) {
                Text("Choose agents")
                    .font(.title3.weight(.semibold))
                Text("Tap a cell, then an agent. Tap the agent again to clear.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            // Live shape of the chosen layout — same glyph family as the chooser.
            SetupCellGrid(
                layout: layout,
                picks: setupPicks,
                tools: agentTools,
                focusIndex: focus,
                onSelectCell: { setupFocusIndex = $0 }
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Space.xs)

            // Even 2-column chip grid so nothing orphans on its own row.
            FlowAgentChips(tools: agentTools, selectedId: pick) { toolId in
                if pick == toolId {
                    setPick(nil, at: focus)
                } else {
                    setPick(toolId, at: focus)
                    // Advance focus so multi-cell setup is click-click-click.
                    if focus + 1 < layout.cellCount {
                        setupFocusIndex = focus + 1
                    }
                }
            }
            .frame(maxWidth: 280)
            .frame(maxWidth: .infinity)

            HStack(spacing: DS.Space.lg) {
                Button("Back") {
                    setupLayout = nil
                    setupPicks = []
                    setupFocusIndex = 0
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)

                Button {
                    startSetup(layout: layout)
                } label: {
                    Text(setupPicks.contains(where: { $0 != nil }) ? "Launch" : "Open empty grid")
                        .font(DS.Font.bodySemibold)
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DS.Space.sm)
    }

    private func chooseLayout(_ layout: GridLayout) {
        setupLayout = layout
        setupPicks = Array(repeating: nil, count: layout.cellCount)
        setupFocusIndex = 0
        // Sensible default: first cell gets the first agent tool if any.
        if let first = agentTools.first {
            setupPicks[0] = first.id
        }
    }

    private func setPick(_ id: UUID?, at index: Int) {
        guard setupPicks.indices.contains(index) else { return }
        setupPicks[index] = id
    }

    private func startSetup(layout: GridLayout) {
        guard let workspace, let projectSession else { return }
        projectSession.resizeWorkspace(workspace, layout: layout)

        var firstLaunched: WorkspaceCell?
        for (index, toolId) in setupPicks.enumerated() {
            guard let toolId,
                  let tool = agentTools.first(where: { $0.id == toolId }),
                  workspace.cells.indices.contains(index) else { continue }
            let cell = workspace.cells[index]
            onLaunch(tool, cell)
            if firstLaunched == nil { firstLaunched = cell }
        }
        // Prefer the first agent we actually started; otherwise attach nothing
        // (empty grid — user stays on the launch pad / start page).
        if let firstLaunched {
            onAttach(firstLaunched)
        }
        setupLayout = nil
        setupPicks = []
        setupFocusIndex = 0
    }

    // MARK: Agents (grid already has runners)

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

/// Even one-tap agent chips (fixed 2 columns) so the palette reads as a
/// tidy centered grid instead of a ragged wrap with a lone last chip.
private struct FlowAgentChips: View {
    let tools: [LaunchTool]
    let selectedId: UUID?
    let onSelect: (UUID) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: DS.Space.xs),
        GridItem(.flexible(), spacing: DS.Space.xs),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: DS.Space.xs) {
            ForEach(tools) { tool in
                let on = tool.id == selectedId
                Button {
                    onSelect(tool.id)
                } label: {
                    HStack(spacing: 5) {
                        quickLaunchIcon(name: tool.icon, size: 12)
                        Text(tool.name)
                            .font(DS.Font.control)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: DS.Control.large)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                            .fill(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                            .strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.08),
                                          lineWidth: on ? 1.5 : 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(on ? "\(tool.name) — tap to clear" : tool.name)
            }
        }
    }
}

/// Interactive mini-map of the chosen layout: one tile per cell, laid out
/// in the real shape (rows/cols). Selected tile gets an accent ring; filled
/// tiles show the agent icon.
private struct SetupCellGrid: View {
    let layout: GridLayout
    let picks: [UUID?]
    let tools: [LaunchTool]
    let focusIndex: Int
    let onSelectCell: (Int) -> Void

    private let tile: CGFloat = 64
    private let gap: CGFloat = 8

    var body: some View {
        let isRows = layout.axis == .rows
        let maxCount = max(1, layout.counts.max() ?? 1)
        let span = CGFloat(maxCount) * tile + CGFloat(maxCount - 1) * gap

        Group {
            if isRows {
                VStack(spacing: gap) {
                    ForEach(Array(layout.counts.enumerated()), id: \.offset) { g, c in
                        HStack(spacing: gap) {
                            ForEach(0..<c, id: \.self) { i in
                                let flat = flatIndex(group: g, index: i)
                                let len = (span - gap * CGFloat(c - 1)) / CGFloat(c)
                                cellTile(flat: flat, width: len, height: tile)
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: gap) {
                    ForEach(Array(layout.counts.enumerated()), id: \.offset) { g, c in
                        VStack(spacing: gap) {
                            ForEach(0..<c, id: \.self) { i in
                                let flat = flatIndex(group: g, index: i)
                                let len = (span - gap * CGFloat(c - 1)) / CGFloat(c)
                                cellTile(flat: flat, width: tile, height: len)
                            }
                        }
                    }
                }
            }
        }
    }

    private func flatIndex(group g: Int, index i: Int) -> Int {
        layout.counts.prefix(g).reduce(0, +) + i
    }

    private func cellTile(flat: Int, width: CGFloat, height: CGFloat) -> some View {
        let focused = flat == focusIndex
        let tool = picks.indices.contains(flat)
            ? picks[flat].flatMap { id in tools.first(where: { $0.id == id }) }
            : nil
        return Button {
            onSelectCell(flat)
        } label: {
            VStack(spacing: 4) {
                if let tool {
                    quickLaunchIcon(name: tool.icon, size: 18)
                    Text(tool.name)
                        .font(DS.Font.footnote)
                        .lineLimit(1)
                } else {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("#\(flat + 1)")
                        .font(DS.Font.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .fill(focused
                          ? Color.accentColor.opacity(0.14)
                          : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.08),
                                  lineWidth: focused ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tool.map { "Cell #\(flat + 1) — \($0.name)" } ?? "Cell #\(flat + 1) — empty")
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
    @FocusState private var urlFieldFocused: Bool

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
            .background(DS.Surface.app)
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
        .background(DS.Surface.app)
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

    /// Fit fills the card; a device preset lays out at the logical device size
    /// (`pageZoom` = 1) and is aspect-fit with a view transform so DOM coords,
    /// hit-testing, and the element picker stay aligned. One subtree for both
    /// cases — branching would re-parent the WKWebView on every switch.
    private var viewportBody: some View {
        GeometryReader { geo in
            let logical = session.viewport.size
            let baseW = logical?.width ?? geo.size.width
            let baseH = logical?.height ?? geo.size.height
            let scale = logical.map {
                min(geo.size.width / $0.width, geo.size.height / $0.height, 1)
            } ?? 1
            WebView(webView: session.webView, pageZoom: 1)
                .frame(width: max(1, baseW), height: max(1, baseH))
                .scaleEffect(scale, anchor: .center)
                .frame(width: max(1, baseW * scale), height: max(1, baseH * scale))
                .overlay(
                    Rectangle()
                        .strokeBorder(Color(nsColor: .separatorColor),
                                      lineWidth: logical == nil ? 0 : 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: scale) { _, new in session.displayScale = new }
                .onAppear { session.displayScale = scale }
        }
        .background(DS.Surface.app, ignoresSafeAreaEdges: [])
        .background {
            // Local shortcuts so they work while the WKWebView has focus
            // (SwiftUI .keyboardShortcut often loses to the web process).
            BrowserKeyMonitor(
                onReload: { session.webView.reload() },
                onBack: { session.goBack() },
                onForward: { session.goForward() },
                onFocusURL: { urlFieldFocused = true },
                onTogglePicker: { session.pickerActive.toggle() }
            )
        }
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
                                 help: "Back (⌘[)",
                                 isEnabled: session.canGoBack) {
                session.goBack()
            }
            BrowserToolbarButton(systemName: "chevron.right",
                                 help: "Forward (⌘])",
                                 isEnabled: session.canGoForward) {
                session.goForward()
            }

            TextField("URL", text: $session.urlString)
                .textFieldStyle(.roundedBorder)
                .font(DS.Font.footnote)
                .focused($urlFieldFocused)
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

            BrowserToolbarButton(systemName: "arrow.clockwise", help: "Reload (⌘R)") {
                session.webView.reload()
            }
            BrowserToolbarButton(systemName: "cursorarrow.rays",
                                 help: session.pickerActive
                                     ? "Annotate on — drag groups peers, ⇧/⌘-click or ⇧-drag adds, Enter sends & exits (Esc clears, ⌘⇧E toggles)"
                                     : "Annotate components for the agent (drag to group · ⇧/⌘-click · ⌘⇧E)",
                                 isActive: session.pickerActive) {
                session.pickerActive.toggle()
            }
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

/// AppKit key monitor for browser chrome shortcuts while the web view has
/// first responder. ⌘←/⌘→ stay reserved for the browser-pane pager.
private struct BrowserKeyMonitor: NSViewRepresentable {
    let onReload: () -> Void
    let onBack: () -> Void
    let onForward: () -> Void
    let onFocusURL: () -> Void
    let onTogglePicker: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(onReload: onReload, onBack: onBack,
                                    onForward: onForward, onFocusURL: onFocusURL,
                                    onTogglePicker: onTogglePicker)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onReload = onReload
        context.coordinator.onBack = onBack
        context.coordinator.onForward = onForward
        context.coordinator.onFocusURL = onFocusURL
        context.coordinator.onTogglePicker = onTogglePicker
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onReload: (() -> Void)?
        var onBack: (() -> Void)?
        var onForward: (() -> Void)?
        var onFocusURL: (() -> Void)?
        var onTogglePicker: (() -> Void)?
        private var monitor: Any?

        func install(onReload: @escaping () -> Void, onBack: @escaping () -> Void,
                     onForward: @escaping () -> Void, onFocusURL: @escaping () -> Void,
                     onTogglePicker: @escaping () -> Void) {
            self.onReload = onReload
            self.onBack = onBack
            self.onForward = onForward
            self.onFocusURL = onFocusURL
            self.onTogglePicker = onTogglePicker
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
                // ⌘R reload
                if flags == .command, chars == "r" {
                    self.onReload?(); return nil
                }
                // ⌘[ back / ⌘] forward (history; pane pager keeps ⌘←/→)
                if flags == .command, chars == "[" {
                    self.onBack?(); return nil
                }
                if flags == .command, chars == "]" {
                    self.onForward?(); return nil
                }
                // ⌘L focus URL bar
                if flags == .command, chars == "l" {
                    self.onFocusURL?(); return nil
                }
                // ⌘⇧E toggle annotate
                if flags == [.command, .shift], chars == "e" {
                    self.onTogglePicker?(); return nil
                }
                return event
            }
        }

        func teardown() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { teardown() }
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
    /// Always 1 for device presets — the card scales the view with
    /// `scaleEffect` so DOM/layout size matches the emulated device and the
    /// picker hit-tests correctly. Fit mode is also 1 (frame = card size).
    var pageZoom: CGFloat = 1

    func makeNSView(context: Context) -> WKWebView { webView }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if abs(nsView.pageZoom - pageZoom) > 0.001 {
            nsView.pageZoom = pageZoom
        }
        // Clear any leftover magnification from older builds.
        if abs(nsView.magnification - 1) > 0.001 {
            nsView.magnification = 1
        }
    }
}

/// Hover the trailing window edge (outside browser mode) to slide a drawer
/// out. Lists open browser panes for quick jump, or offers “Open browser” for
/// the active workspace when none exist. ⌘B still toggles full browser mode;
/// this is only a picker / start affordance.
///
/// The edge strip uses a hit-through AppKit tracker so it never steals clicks
/// from cell chrome underneath (close ✕ on right-edge cells). A short dwell
/// before reveal stops the drawer from flashing open while aiming at those
/// buttons.
struct BrowserEdgeDrawer: View {
    @Bindable var manager: BrowserManager
    /// Active project session — used for “open browser on this workspace”.
    var projectSession: ProjectSession?
    let onSelect: (BrowserSession) -> Void
    let onStartBrowser: () -> Void

    @State private var edgeHover = false
    @State private var panelHover = false
    /// Actually visible — lags edge hover by `showDelay` so quick trips to
    /// the cell close button don't open the drawer.
    @State private var revealed = false
    @State private var showWorkItem: DispatchWorkItem?
    @State private var hideWorkItem: DispatchWorkItem?

    private var open: Bool { revealed }

    /// How long the pointer must stay on the edge before the drawer opens.
    private static let showDelay: TimeInterval = 0.25
    /// Grace when crossing the gap between hot zone and panel.
    private static let hideDelay: TimeInterval = 0.18

    /// Leading corners of a right-edge drawer (mirror of the file editor's
    /// trailing corners on its left-edge panel).
    private var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: DS.Radius.lg,
            bottomLeadingRadius: DS.Radius.lg,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    var body: some View {
        // ZStack keeps the panel flush to the window's trailing edge.
        // Panel sits above the hot zone when open so its buttons stay clickable;
        // the strip itself never participates in hit-testing (clicks pass
        // through to cell close / zoom underneath).
        ZStack(alignment: .trailing) {
            EdgeHoverStrip(onHover: setEdgeHover)
                .frame(width: 14)
                .frame(maxHeight: .infinity)
                .help(manager.sessions.isEmpty
                      ? "Hover for browser — open one for this workspace"
                      : "Hover to pick an open browser")

            if open {
                panel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .onHover { setPanelHover($0) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .animation(.easeOut(duration: 0.16), value: open)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "globe")
                    .font(.system(size: DS.Icon.small, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(manager.sessions.isEmpty ? "Browser" : "Browsers")
                    .font(DS.Font.bodySemibold)
                Spacer(minLength: 0)
                if !manager.sessions.isEmpty {
                    Text("\(manager.sessions.count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
            .padding(.horizontal, DS.Space.md)
            .frame(height: DS.Control.header)

            Divider()

            if manager.sessions.isEmpty {
                emptyBody
            } else {
                sessionList
            }
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity)
        .background(DS.Surface.app)
        .clipShape(panelShape)
        .overlay(
            panelShape
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 14, x: -4, y: 0)
    }

    private var emptyBody: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("No browsers open")
                .font(DS.Font.bodySemibold)
            Text(workspaceHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onStartBrowser) {
                Label("Open browser", systemImage: "globe")
                    .font(DS.Font.control)
                    .frame(maxWidth: .infinity)
                    .frame(height: DS.Control.large)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(projectSession?.activeWorkspace == nil)
            .help(projectSession?.activeWorkspace == nil
                  ? "Select a project with a workspace first"
                  : "Open a browser for the active workspace (or press ⌘B)")

            Text("Tip: ⌘B toggles full browser mode anytime.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)
        }
        .padding(DS.Space.lg)
    }

    private var workspaceHint: String {
        if let name = projectSession?.activeWorkspace?.name {
            return "Start one for “\(name)” — servers, agents, and localhost preview."
        }
        return "Select a project workspace, then open a browser here."
    }

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: DS.Space.xxs) {
                ForEach(manager.sessions) { session in
                    Button {
                        onSelect(session)
                    } label: {
                        sessionRow(session)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DS.Space.sm)
        }
    }

    private func sessionRow(_ session: BrowserSession) -> some View {
        let focused = manager.focusedId == session.id
        return HStack(alignment: .top, spacing: DS.Space.sm) {
            Image(systemName: "globe")
                .font(.system(size: DS.Icon.small, weight: .semibold))
                .foregroundStyle(focused ? Color.accentColor : .secondary)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(sessionTitle(session))
                    .font(DS.Font.control)
                    .fontWeight(focused ? .semibold : .regular)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(sessionSubtitle(session))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, DS.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(focused ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
        )
        .contentShape(Rectangle())
        .help("Open this browser")
    }

    private func sessionTitle(_ session: BrowserSession) -> String {
        let title = session.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if !session.urlString.isEmpty { return session.urlString }
        if let agent = session.ownerTab?.title, !agent.isEmpty { return agent }
        if session.wasOpenedManually { return "Workspace browser" }
        return "Browser"
    }

    private func sessionSubtitle(_ session: BrowserSession) -> String {
        var parts: [String] = []
        if let agent = session.ownerTab?.title, !agent.isEmpty {
            parts.append(agent)
        } else if session.ownerCell != nil {
            parts.append("Empty cell")
        } else if let ws = session.sourceWorkspace?.name {
            parts.append(ws)
        }
        let url = session.urlString
        if !url.isEmpty, url != sessionTitle(session) {
            parts.append(url)
        }
        return parts.isEmpty ? "Blank" : parts.joined(separator: " · ")
    }

    private func setEdgeHover(_ hovering: Bool) {
        edgeHover = hovering
        if hovering {
            hideWorkItem?.cancel()
            scheduleShowIfNeeded()
        } else {
            showWorkItem?.cancel()
            scheduleHideIfNeeded()
        }
    }

    private func setPanelHover(_ hovering: Bool) {
        panelHover = hovering
        if hovering {
            // Already on the panel — open immediately and keep it.
            hideWorkItem?.cancel()
            showWorkItem?.cancel()
            revealed = true
        } else {
            scheduleHideIfNeeded()
        }
    }

    private func scheduleShowIfNeeded() {
        showWorkItem?.cancel()
        guard !revealed else { return }
        // Cancelled in setEdgeHover(false) if the pointer leaves before delay.
        let work = DispatchWorkItem { revealed = true }
        showWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: work)
    }

    private func scheduleHideIfNeeded() {
        hideWorkItem?.cancel()
        // Keep the panel up briefly when crossing from hot zone → panel so it
        // doesn't flicker closed in the gap.
        guard !edgeHover, !panelHover else { return }
        let work = DispatchWorkItem {
            revealed = false
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: work)
    }
}

/// Full-height trailing strip that reports hover without intercepting clicks.
/// Cell header controls (close, zoom) on right-edge cells sit under this zone;
/// a normal SwiftUI `Color.clear` + `contentShape` would steal their hits.
private struct EdgeHoverStrip: NSViewRepresentable {
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> EdgeHoverNSView {
        let view = EdgeHoverNSView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: EdgeHoverNSView, context: Context) {
        nsView.onHover = onHover
    }
}

private final class EdgeHoverNSView: NSView {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    /// Pass every mouse event through to the views underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}
