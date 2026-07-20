import AppKit
import Foundation
import Observation
import WebKit

/// All live agent browser panes, in creation order. One pane per owning
/// terminal (the agent that opened it via `agentide browser open`), plus
/// workspace-scoped manual browsers from the header globe. Also owns the
/// browser-mode UI state: whether the full-window browser view is up and
/// which pane it shows. Ephemeral — nothing is persisted.
@Observable
final class BrowserManager {
    static let shared = BrowserManager()

    private(set) var sessions: [BrowserSession] = []
    var focusedId: UUID?
    /// True while the full-window browser mode (agent column + web view)
    /// replaces the normal three-pane layout. Always mutate via `setModeActive`
    /// so MainWindow receives `.browserModeDidChange`.
    private(set) var isModeActive = false

    private init() {}

    /// Single writer for mode visibility. Posts `.browserModeDidChange` so
    /// MainWindow's `@State` flag stays in sync (Observation through a shared
    /// singleton was missing updates and trapped people in browser view).
    func setModeActive(_ active: Bool) {
        guard isModeActive != active else { return }
        isModeActive = active
        NotificationCenter.default.post(name: .browserModeDidChange, object: active)
    }

    var focused: BrowserSession? {
        sessions.first(where: { $0.id == focusedId }) ?? sessions.first
    }

    func session(for cell: WorkspaceCell) -> BrowserSession? {
        sessions.first(where: { $0.ownerCell === cell })
    }

    /// Open (or navigate) the browser pane bound to this grid cell. Creating
    /// a pane is listed in the hover drawer; it never auto-expands browser
    /// mode — the user chooses when to look (⌘B / drawer / globe). A nil url
    /// opens the blank start page.
    @discardableResult
    func open(_ url: URL?, cell: WorkspaceCell,
              workspace: Workspace? = nil,
              projectSession: ProjectSession? = nil) -> BrowserSession {
        let session: BrowserSession
        if let existing = self.session(for: cell) {
            session = existing
            session.bindContext(workspace: workspace, projectSession: projectSession)
        } else {
            session = BrowserSession(cell: cell, workspace: workspace, projectSession: projectSession)
            sessions.append(session)
            if focusedId == nil { focusedId = session.id }
        }
        if let url { session.load(url) }
        return session
    }

    /// User-opened browser (workspace-header globe / restore). One reusable
    /// session per workspace: reopening focuses the existing pane instead of
    /// stacking blanks. Expands browser mode immediately so the launch pad is
    /// visible. Marks the workspace so relaunch re-opens browser mode.
    func openManual(from workspace: Workspace, projectSession: ProjectSession) {
        if !workspace.prefersBrowserMode {
            workspace.prefersBrowserMode = true
            projectSession.markDirty()
        }
        if let existing = sessions.first(where: {
            $0.sourceWorkspace === workspace && ($0.ownerCell == nil || $0.wasOpenedManually)
        }) {
            existing.bindContext(workspace: workspace, projectSession: projectSession)
            focusedId = existing.id
            setModeActive(true)
            return
        }
        let session = BrowserSession(cell: nil, workspace: workspace,
                                     projectSession: projectSession, openedManually: true)
        sessions.append(session)
        focusedId = session.id
        setModeActive(true)
    }

    /// Collapse browser mode to the grid (⌘B / Grid button). Keeps
    /// `prefersBrowserMode` so the next app launch can restore browser mode;
    /// does NOT auto-reopen on the same run.
    func collapseMode() {
        setModeActive(false)
    }

    /// Expand browser mode (⌘B when collapsed). Always prefers the **selected
    /// project's active workspace** — never just "whatever pane happens to be
    /// open" (that left people on another project's blank browser with
    /// "Set up servers" while the selected project already had servers).
    func expandMode(projectSession: ProjectSession?) {
        if let projectSession, let ws = projectSession.activeWorkspace {
            if let existing = session(matching: projectSession, workspace: ws) {
                // Refresh weak refs — ProjectSession can be recreated and leave
                // projectSession nil, which made the server strip look empty.
                existing.bindContext(workspace: ws, projectSession: projectSession)
                focusedId = existing.id
                setModeActive(true)
                return
            }
            openManual(from: ws, projectSession: projectSession)
            return
        }
        // No project/workspace selection — only then fall back to any open pane.
        if !sessions.isEmpty {
            setModeActive(true)
        }
    }

    /// Best existing pane for this project/workspace (manual or agent-bound).
    private func session(matching projectSession: ProjectSession,
                         workspace: Workspace) -> BrowserSession? {
        if let s = sessions.first(where: { $0.sourceWorkspace === workspace }) {
            return s
        }
        if let s = sessions.first(where: { session in
            guard let cell = session.ownerCell else { return false }
            return workspace.cells.contains(where: { $0 === cell })
        }) {
            return s
        }
        if let s = sessions.first(where: { $0.projectSession === projectSession }) {
            return s
        }
        if let s = sessions.first(where: {
            $0.projectSession?.projectId == projectSession.projectId
        }) {
            return s
        }
        return nil
    }

    /// ⌘B: open browser mode if collapsed, collapse to grid if open.
    func toggleMode(projectSession: ProjectSession?) {
        if isModeActive {
            collapseMode()
        } else {
            expandMode(projectSession: projectSession)
        }
    }

    func close(_ session: BrowserSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: idx)
        session.tearDown()
        // Closing the workspace's own pane withdraws the browser preference —
        // otherwise every return to the workspace re-opens a browser the user
        // explicitly closed.
        if session.wasOpenedManually || session.ownerCell == nil,
           let ws = session.sourceWorkspace, ws.prefersBrowserMode {
            ws.prefersBrowserMode = false
            session.projectSession?.markDirty()
        }
        if focusedId == session.id { focusedId = sessions.first?.id }
        // Always leave browser mode when the focused pane is closed; if other
        // panes remain, stay only if mode was already showing them.
        if sessions.isEmpty || focusedId == nil {
            setModeActive(false)
        }
    }

    /// Force-exit browser mode and drop every pane (escape hatch).
    func closeAll() {
        for session in sessions { session.tearDown() }
        sessions.removeAll()
        focusedId = nil
        setModeActive(false)
    }

    /// A cell leaving the grid (workspace removed/resized) takes its browser
    /// with it. Closing just the cell's PROGRAM does not — the browser stays
    /// and the left column shows the launcher so a different agent can take
    /// over.
    func close(boundTo cell: WorkspaceCell) {
        guard let session = session(for: cell) else { return }
        close(session)
    }

    /// Drop every browser that was opened from (or later bound to) this
    /// workspace — used when the workspace itself is deleted.
    func close(workspace: Workspace) {
        let toClose = sessions.filter { session in
            if session.sourceWorkspace === workspace { return true }
            guard let cell = session.ownerCell else { return false }
            return workspace.cells.contains(where: { $0 === cell })
        }
        for session in toClose { close(session) }
    }

    /// Cycle the focused pane (bottom pager arrows).
    func focusNext(_ step: Int) {
        guard sessions.count > 1 else { return }
        let idx = sessions.firstIndex(where: { $0.id == focused?.id }) ?? 0
        focusedId = sessions[(idx + step + sessions.count) % sessions.count].id
    }

    /// `example.com` → `https://example.com`; bare localhost / loopback hosts
    /// get plain http since dev servers rarely speak TLS.
    static func normalizeURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") {
            let insecure = s.hasPrefix("localhost") || s.hasPrefix("127.") || s.hasPrefix("0.0.0.0")
            s = (insecure ? "http://" : "https://") + s
        }
        return URL(string: s)
    }
}

/// Scrapes localhost / loopback URLs from terminal screens across a project
/// session — the working grid plus the dedicated Servers workspace. Dev
/// servers print these at boot (vite, next, rails, Go `listening on :8080`, …).
enum LocalServerURLDetector {
    /// Full http(s) URLs on loopback (port optional — some tools omit it for 80).
    private static let fullURL =
        /https?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::\d+)?(?:\/[^\s"'<>]*)?/
    /// Bare `host:port` that vite/webpack-style log lines sometimes print
    /// without a scheme (e.g. after "Local:" with ANSI codes stripped poorly).
    private static let bareHostPort =
        /(?:localhost|127\.0\.0\.1|0\.0\.0\.0):\d{2,5}\b/
    /// Private LAN URLs (vite "Network:") — useful when localhost is busy.
    private static let privateLAN =
        /https?:\/\/(?:192\.168\.\d{1,3}\.\d{1,3}|10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3}):\d+[^\s"'<>]*/
    /// Go / node / rust style: `listening on :8080`, `Listening on 0.0.0.0:3000`,
    /// `serving on [::]:5173`, `bound to :4000`. Capture group = port.
    private static let listenOnPort =
        /(?i)(?:listen(?:ing)?|bound|serv(?:ing|ed)|ready|started|available|running)\s+(?:on|at|to)\s+(?:https?:\/\/)?(?:\*|0\.0\.0\.0|127\.0\.0\.1|localhost|\[::\]|\[::1\])?:(\d{2,5})\b/
    /// `port 8080` / `port: 8080` near a listen/server keyword on the same line.
    private static let portKeyword =
        /(?i)(?:listen(?:ing)?|server|http|ready|started|bound).{0,40}?\bport[:\s]+(\d{2,5})\b/
    /// CSI / OSC noise Ghostty sometimes includes in screen text.
    private static let ansi = /\u{001B}(?:\[[0-9;?]*[A-Za-z]|\][^\u{0007}]*\u{0007})/

    /// Ordered unique URLs found on any live terminal in the project session.
    /// Prefer the Servers workspace first so named dev servers win over
    /// incidental agent-cell noise.
    static func detect(in projectSession: ProjectSession?) -> [String] {
        guard let projectSession else { return [] }
        var seen = Set<String>()
        var urls: [String] = []
        let ordered = projectSession.workspaces.sorted { a, b in
            let aServers = a.name == ServerRunner.workspaceName
            let bServers = b.name == ServerRunner.workspaceName
            if aServers != bServers { return aServers }
            return false
        }
        for workspace in ordered {
            for cell in workspace.cells {
                guard let raw = cell.terminal?.view.readScreenText(), !raw.isEmpty else { continue }
                appendURLs(from: stripANSI(raw), into: &urls, seen: &seen)
            }
        }
        return urls
    }

    private static func stripANSI(_ text: String) -> String {
        text.replacing(ansi, with: "")
    }

    private static func appendURLs(from text: String, into urls: inout [String], seen: inout Set<String>) {
        for match in text.matches(of: fullURL) {
            push(String(match.output), into: &urls, seen: &seen)
        }
        for match in text.matches(of: privateLAN) {
            push(String(match.output), into: &urls, seen: &seen)
        }
        for match in text.matches(of: bareHostPort) {
            push("http://\(String(match.output))", into: &urls, seen: &seen)
        }
        for match in text.matches(of: listenOnPort) {
            let port = String(match.output.1)
            push("http://localhost:\(port)", into: &urls, seen: &seen)
        }
        for match in text.matches(of: portKeyword) {
            let port = String(match.output.1)
            push("http://localhost:\(port)", into: &urls, seen: &seen)
        }
    }

    private static func push(_ raw: String, into urls: inout [String], seen: inout Set<String>) {
        var url = raw
        // Strip trailing punctuation commonly left by log formatters.
        while let last = url.last, ".,);]>".contains(last) { url.removeLast() }
        // Collapse 0.0.0.0 (bind-all) to localhost for the browser.
        if let range = url.range(of: "://0.0.0.0") {
            url.replaceSubrange(range, with: "://localhost")
        }
        guard !url.isEmpty, seen.insert(url).inserted else { return }
        urls.append(url)
    }
}

/// Device viewport presets for the browser pane. `fit` fills the card 1:1;
/// the rest lay the page out at the device's logical resolution and
/// aspect-fit it into the card via AppKit bounds scaling (frame = visual
/// size, bounds = device size) so CSS layout, hit-testing, and the element
/// picker all share one coordinate space.
enum BrowserViewport: String, CaseIterable, Identifiable {
    case fit, desktop, laptop, tablet, mobile

    var id: String { rawValue }

    /// Logical CSS-pixel size; nil = fluid (fill the card).
    var size: CGSize? {
        switch self {
        case .fit:     return nil
        case .desktop: return CGSize(width: 1920, height: 1080)
        case .laptop:  return CGSize(width: 1440, height: 900)
        case .tablet:  return CGSize(width: 820, height: 1180)
        case .mobile:  return CGSize(width: 390, height: 844)
        }
    }

    var title: String {
        switch self {
        case .fit:     return "Fit"
        case .desktop: return "Desktop (1920×1080)"
        case .laptop:  return "Laptop (1440×900)"
        case .tablet:  return "Tablet (820×1180)"
        case .mobile:  return "Mobile (390×844)"
        }
    }

    var symbol: String {
        switch self {
        case .fit:     return "rectangle.dashed"
        case .desktop: return "desktopcomputer"
        case .laptop:  return "laptopcomputer"
        case .tablet:  return "ipad"
        case .mobile:  return "iphone"
        }
    }
}

/// One agent-owned browser pane: the WKWebView, the element picker, and the
/// JS-eval plumbing the `agentide browser` verbs use. Owned by BrowserManager;
/// tied to a workspace (for multi-cell agent pick + server URL scan) and
/// optionally a driving cell (picker selections land in that terminal).
@Observable
final class BrowserSession: NSObject, Identifiable, WKNavigationDelegate, WKScriptMessageHandler {
    let id = UUID()
    /// The grid cell this browser is bound to — the browser belongs to the
    /// CELL, not to a specific program: close the cell's agent and launch a
    /// different one, and the new agent inherits this pane. nil for a
    /// user-opened browser until a cell is attached.
    private(set) weak var ownerCell: WorkspaceCell?
    /// Workspace the launch pad / agent picker draws from. Set for manual
    /// opens and for agent-opened panes once context is bound.
    private(set) weak var sourceWorkspace: Workspace?
    /// Project session — used to find the Servers workspace and all cells
    /// when scanning for localhost URLs / listing agents.
    private(set) weak var projectSession: ProjectSession?
    /// True when opened from the workspace globe (vs `agentide browser open`).
    /// Manual browsers auto-load the first detected localhost URL.
    let wasOpenedManually: Bool
    let webView: WKWebView

    /// The agent currently driving this pane (the bound cell's live
    /// terminal). Picker selections land here.
    var ownerTab: TerminalTab? { ownerCell?.terminal }

    var urlString: String = ""
    var pageTitle: String = ""
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    /// Emulated device screen size (toolbar menu or `agentide browser
    /// viewport`). ponytail: layout size + view scale only — no mobile
    /// user-agent or touch-event emulation; add a UA switch if a site
    /// serves a genuinely different mobile experience.
    var viewport: BrowserViewport = .fit
    /// Aspect-fit scale applied by the browser column (1 for fit / when the
    /// card is larger than the device). Used for element screenshot rects.
    var displayScale: CGFloat = 1
    /// Annotation picker: while on, hover/drag highlights a component range
    /// and a chip lets the user type a change note that submits into the
    /// owning agent's input.
    var pickerActive = false {
        didSet { applyPicker() }
    }
    /// When true (manual browsers default), the start page loads the first
    /// newly-seen localhost URL as soon as a terminal prints one.
    var autoLoadDetectedURLs: Bool

    /// KVO on WKWebView.url / title / history — catches SPA pushState and
    /// in-page navigations that never fire WKNavigationDelegate.
    private var webViewObservations: [NSKeyValueObservation] = []

    init(cell: WorkspaceCell?, workspace: Workspace? = nil,
         projectSession: ProjectSession? = nil, openedManually: Bool = false) {
        self.ownerCell = cell
        self.sourceWorkspace = workspace
        self.projectSession = projectSession
        self.wasOpenedManually = openedManually
        self.autoLoadDetectedURLs = openedManually

        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.pickerJS,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: Self.consoleCaptureJS,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        self.webView = webView
        super.init()
        // Weak proxy: WKUserContentController retains its handlers, so adding
        // self directly would create a retain cycle through our own webView.
        controller.add(WeakScriptMessageHandler(self), name: "agentidePicker")
        webView.navigationDelegate = self
        startObservingWebView()
    }

    /// Fill in (or refresh) workspace / project context. Non-nil args always
    /// overwrite — `projectSession` is weak and can go nil when SessionManager
    /// recreates the session, which would empty the server strip.
    func bindContext(workspace: Workspace?, projectSession: ProjectSession?) {
        if let workspace { sourceWorkspace = workspace }
        if let projectSession { self.projectSession = projectSession }
    }

    private func startObservingWebView() {
        // url KVO is what keeps the address bar honest on client-side routing.
        // WKWebView KVO can fire off the main thread — hop back before mutating
        // @Observable state so SwiftUI updates stay coherent.
        func onMain(_ body: @escaping () -> Void) {
            if Thread.isMainThread { body() }
            else { DispatchQueue.main.async(execute: body) }
        }
        webViewObservations = [
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                let url = wv.url
                onMain {
                    guard let self else { return }
                    if let url { self.urlString = url.absoluteString }
                    self.syncNavigationState()
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                let title = wv.title ?? ""
                onMain { self?.pageTitle = title }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                let loading = wv.isLoading
                onMain { self?.isLoading = loading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                let v = wv.canGoBack
                onMain { self?.canGoBack = v }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                let v = wv.canGoForward
                onMain { self?.canGoForward = v }
            },
        ]
        syncNavigationState()
    }

    private func syncNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        if let title = webView.title { pageTitle = title }
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    /// Bind (or rebind) the driving cell. The cell's agent — current and
    /// future — owns this pane: its `agentide browser` verbs hit it and
    /// picker selections land in its input. Rebinding lets a multi-cell
    /// workspace hand the same browser to a different agent.
    func attach(to cell: WorkspaceCell) {
        ownerCell = cell
    }

    /// Drop the driving cell without closing the browser (left column returns
    /// to the agent picker).
    func detachAgent() {
        ownerCell = nil
    }

    func load(_ url: URL) {
        urlString = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func tearDown() {
        pickerActive = false
        webViewObservations.removeAll()
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
    }

    // MARK: - Agent verbs

    /// Call back once the page finishes loading, or after `timeout` seconds
    /// (passes false). The initial grace tick lets a just-issued `load()`
    /// flip `webView.isLoading` before the first check — otherwise `open`
    /// followed by `read` races the navigation and snapshots a blank page.
    func whenLoaded(timeout: TimeInterval = 10, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if !webView.isLoading { completion(true) }
            else if Date() >= deadline { completion(false) }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { poll() }
    }

    /// Poll a JS expression until it is truthy, for `agentide browser wait`.
    /// The SPA counterpart of `whenLoaded` — load finished ≠ content
    /// rendered (data fetches, spinners, route transitions).
    func waitFor(_ expr: String, timeout: TimeInterval = 10, completion: @escaping (String) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        let js = "!!(\(expr))"
        func poll() {
            webView.evaluateJavaScript(js) { result, error in
                if let error {
                    let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                    completion("error: \(detail ?? error.localizedDescription)")
                } else if (result as? Bool) == true {
                    completion("ok: condition is truthy")
                } else if Date() >= deadline {
                    completion("error: condition still falsy after \(Int(timeout))s")
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
                }
            }
        }
        poll()
    }

    /// Run JS in the page and hand back a printable result string.
    func eval(_ js: String, completion: @escaping (String) -> Void) {
        webView.evaluateJavaScript(js) { result, error in
            if let error {
                let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                completion("error: \(detail ?? error.localizedDescription)")
            } else if let s = result as? String {
                completion(s.isEmpty ? "ok" : s)
            } else if let result {
                if JSONSerialization.isValidJSONObject(result),
                   let data = try? JSONSerialization.data(withJSONObject: result,
                                                          options: [.prettyPrinted, .sortedKeys]),
                   let json = String(data: data, encoding: .utf8) {
                    completion(json)
                } else {
                    completion(String(describing: result))
                }
            } else {
                completion("ok")
            }
        }
    }

    /// Compact page snapshot for `agentide browser read`: title, url,
    /// interactive elements with CSS selectors, then visible text.
    func snapshot(completion: @escaping (String) -> Void) {
        eval(Self.snapshotJS, completion: completion)
    }

    /// Console errors/warnings, uncaught exceptions, and failed network
    /// requests collected by the injected capture script. Resets on every
    /// navigation (fresh page context), which is the correct scope for
    /// "did THIS page load clean".
    func consoleErrors(completion: @escaping (String) -> Void) {
        eval("(window.__agentideLogs || []).filter(function (l) { return !/^(log|info):/.test(l); })"
             + ".join('\\n') "
             + "|| '(no console errors, warnings, or failed requests since page load)'",
             completion: completion)
    }

    /// Everything the capture script collected — console.log/info included —
    /// for `agentide browser logs`. The agent's printf-debugging channel.
    func consoleLogs(completion: @escaping (String) -> Void) {
        eval("(window.__agentideLogs || []).join('\\n') || '(no console output since page load)'",
             completion: completion)
    }

    /// JSON-escape a string for splicing into injected JS.
    private static func jsQuoted(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data()
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    /// Outer HTML of the first element matching `selector` (whole document
    /// if empty) for `agentide browser html` — the raw markup `snapshot`'s
    /// lossy summary can't show.
    func html(selector: String, completion: @escaping (String) -> Void) {
        let quoted = selector.isEmpty ? "null" : Self.jsQuoted(selector)
        eval("""
            (function () {
              var sel = \(quoted);
              var el = sel ? document.querySelector(sel) : document.documentElement;
              if (!el) { return 'error: no element matches ' + sel; }
              return el.outerHTML.slice(0, 8000);
            })();
            """, completion: completion)
    }

    /// PNG of the current page (or just the element matching `selector`),
    /// written to a temp file the calling agent can read. Only works while
    /// the pane is on screen — a detached WKWebView has zero bounds and
    /// snapshots blank.
    func screenshot(selector: String = "", completion: @escaping (String) -> Void) {
        guard webView.window != nil, !webView.bounds.isEmpty else {
            completion("error: the browser pane is not on screen — "
                       + "ask the user to expand browser mode (⌘B), then retry")
            return
        }
        guard !selector.isEmpty else {
            capture(rect: nil, completion: completion)
            return
        }
        eval("""
            (function () {
              var el = document.querySelector(\(Self.jsQuoted(selector)));
              if (!el) { return 'none'; }
              el.scrollIntoView({ block: 'center', behavior: 'instant' });
              var r = el.getBoundingClientRect();
              return [r.x, r.y, r.width, r.height].join(',');
            })();
            """) { [weak self] result in
            guard let self else { return }
            let parts = result.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4, parts[2] > 0, parts[3] > 0 else {
                completion(result == "none"
                           ? "error: no element matches \(selector)"
                           : "error: element has no visible bounds")
                return
            }
            // DOM rects are in the logical (unscaled) web view; the view is
            // laid out at device size so snapshot space matches 1:1.
            capture(rect: CGRect(x: parts[0], y: parts[1],
                                 width: parts[2], height: parts[3]),
                    completion: completion)
        }
    }

    private func capture(rect: CGRect?, completion: @escaping (String) -> Void) {
        let config = rect.map { r in
            let c = WKSnapshotConfiguration()
            c.rect = r
            return c
        }
        webView.takeSnapshot(with: config) { image, error in
            guard let image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                completion("error: \(error?.localizedDescription ?? "could not encode snapshot")")
                return
            }
            let name = "agentide-browser-\(Int(Date().timeIntervalSince1970)).png"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            do {
                try png.write(to: url)
                Self.pruneScreenshots(keeping: 20)
                completion("ok: screenshot saved — read this image file to view it: \(url.path)")
            } catch {
                completion("error: \(error.localizedDescription)")
            }
        }
    }

    /// Bounded storage for screenshots: on every capture, delete all but the
    /// newest `keeping` agentide-browser-*.png in the temp dir. An agent can
    /// take 1000 screenshots and disk usage stays ~20 files; macOS's own
    /// temp cleanup remains the backstop for the survivors.
    private static func pruneScreenshots(keeping: Int) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        guard let files = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: .skipsHiddenFiles) else { return }
        let shots = files
            .filter { $0.lastPathComponent.hasPrefix("agentide-browser-") && $0.pathExtension == "png" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        for stale in shots.dropFirst(keeping) {
            try? fm.removeItem(at: stale)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        // Provisional URL updates earlier than didCommit for typed navigations.
        if let url = webView.url {
            urlString = url.absoluteString
        }
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        urlString = webView.url?.absoluteString ?? urlString
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        urlString = webView.url?.absoluteString ?? urlString
        pageTitle = webView.title ?? ""
        syncNavigationState()
        // The picker script re-injects on navigation but wakes up dormant.
        if pickerActive { applyPicker() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        isLoading = false
        syncNavigationState()
    }

    // MARK: - Picker

    private func applyPicker() {
        if pickerActive {
            // Tear down + re-inject so script fixes ship without a full navigation
            // (user scripts alone only run on document load).
            webView.evaluateJavaScript(
                """
                try {
                  if (window.__agentidePicker && window.__agentidePicker.destroy) {
                    window.__agentidePicker.destroy();
                  }
                } catch (e) {}
                window.__agentidePicker = null;
                """
            ) { [weak self] _, _ in
                guard let self else { return }
                self.webView.evaluateJavaScript(Self.pickerJS) { _, _ in
                    self.webView.evaluateJavaScript(
                        "window.__agentidePicker && window.__agentidePicker.setActive(true)",
                        completionHandler: nil)
                }
            }
        } else {
            webView.evaluateJavaScript(
                "window.__agentidePicker && window.__agentidePicker.setActive(false)",
                completionHandler: nil)
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "agentidePicker",
              let dict = message.body as? [String: Any] else { return }

        let action = (dict["action"] as? String) ?? ""
        // Esc with empty selection exits annotate mode (JS already cleared).
        if action == "cancel" {
            pickerActive = false
            return
        }

        // Prefer multi-select `selectors` array; fall back to single `selector`.
        var selectors: [String] = []
        if let multi = dict["selectors"] as? [String] {
            selectors = multi.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else if let one = dict["selector"] as? String, !one.isEmpty {
            selectors = [one]
        }
        guard !selectors.isEmpty else { return }

        let text = (dict["text"] as? String) ?? ""
        let html = (dict["html"] as? String) ?? ""
        let note = ((dict["note"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAction = action.isEmpty
            ? (note.isEmpty ? "pick" : "annotate")
            : action

        let selectorSummary: String
        if selectors.count == 1 {
            selectorSummary = selectors[0]
        } else {
            selectorSummary = "\(selectors.count) elements: " + selectors.joined(separator: " ;; ")
        }

        var line = resolvedAction == "annotate"
            ? "[browser annotate] \(selectorSummary)"
            : "[browser pick] \(selectorSummary)"
        if !text.isEmpty { line += " | text: \"\(text)\"" }
        if !html.isEmpty { line += " | html: \(html)" }
        if !note.isEmpty { line += " | \(note)" }

        // Must stay newline-free or the agent CLI submits early / splits the prompt.
        let flat = line.replacingOccurrences(of: "\n", with: " ")
        // Annotate (chip + Enter) submits immediately. Bare pick (legacy) still
        // inserts without submit so the user can append more context first.
        let submit = resolvedAction == "annotate" && !note.isEmpty
        ownerTab?.view.sendInput(submit ? flat : flat + " ", submit: submit)

        // Annotate send: clear highlights and leave annotate mode so the user
        // can browse again. Toggle ⌘⇧E to pick more. (JS already setActive(false);
        // this updates the toolbar button state.)
        if submit {
            pickerActive = false
        }
    }

    // MARK: - Injected JS

    /// Element picker with multi-select (marquee + shift/cmd-click), highlight
    /// overlays + element outlines, and a floating annotation chip. Dormant
    /// until `setActive(true)`. Enter sends the note, clears selection, and
    /// Swift turns annotate mode off.
    private static let pickerJS = #"""
    (function () {
      if (window.__agentidePicker) { return; }

      var HL_CLASS = 'agentide-hl';
      var HL_STYLE_ID = 'agentide-hl-style';
      // Fixed overlays + extreme z-index for normal pages. Inside an open
      // <dialog>/drawer we reparent into that host (mountNear) so we share its
      // top layer — do NOT use the Popover API for chrome: [popover] applies
      // display:none !important until showPopover(), and a failed open leaves
      // the annotation chip permanently invisible while outlines still work.
      // Overlay layer: fixed inset:0, pointer-events:none so page still receives
      // hits except on interactive chrome (chip) which opts back in with auto.
      // Chrome children use position:absolute with coords relative to this layer.
      // Critical for dialogs/drawers: many use transform, which makes position:fixed
      // resolve against the modal — feeding viewport getBoundingClientRect() into
      // left/top then paints a second, shifted ghost highlight.
      var LAYER =
        'position:fixed;left:0;top:0;right:0;bottom:0;width:100%;height:100%;' +
        'z-index:2147483647;pointer-events:none;overflow:visible;';
      var HIGHLIGHT =
        'position:absolute;pointer-events:none;box-sizing:border-box;' +
        'border:2px solid #007AFF;background:rgba(0,122,255,0.16);border-radius:4px;' +
        'box-shadow:0 0 0 1px rgba(0,122,255,0.35);display:none;';
      var MARQUEE =
        'position:absolute;pointer-events:none;box-sizing:border-box;' +
        'border:1.5px dashed #007AFF;background:rgba(0,122,255,0.08);display:none;';
      var CHIP =
        'position:absolute;display:none;box-sizing:border-box;' +
        'pointer-events:auto;min-width:240px;max-width:380px;padding:6px 8px;border-radius:10px;' +
        'background:rgba(28,28,30,0.96);border:1px solid rgba(255,255,255,0.12);' +
        'box-shadow:0 8px 28px rgba(0,0,0,0.45);font:12px -apple-system,system-ui,sans-serif;' +
        'color:#f5f5f7;';

      var boxPool = [];
      var layer = document.createElement('div');
      layer.setAttribute('data-agentide-ui', '1');
      layer.setAttribute('data-agentide-layer', '1');
      layer.style.cssText = LAYER;

      var marquee = document.createElement('div');
      marquee.setAttribute('data-agentide-ui', '1');
      marquee.style.cssText = MARQUEE;

      var chip = document.createElement('div');
      chip.setAttribute('data-agentide-ui', '1');
      chip.style.cssText = CHIP;
      chip.innerHTML =
        '<div data-agentide-ui="1" data-agentide-hint ' +
        'style="font-size:10px;opacity:0.55;margin:0 0 4px 2px;letter-spacing:0.02em;' +
        'pointer-events:none;">' +
        'Annotate · Enter sends & exits · Esc clears · ⇧/⌘-click or ⇧-drag groups</div>' +
        '<input type="text" data-agentide-ui="1" placeholder="What should change?" ' +
        'style="width:100%;box-sizing:border-box;border:none;outline:none;' +
        'pointer-events:auto;background:rgba(255,255,255,0.08);color:#f5f5f7;border-radius:6px;' +
        'padding:7px 9px;font:12px -apple-system,system-ui,sans-serif;" />';
      var input = chip.querySelector('input');
      var hint = chip.querySelector('[data-agentide-hint]');

      var state = {
        active: false,
        selected: [],
        hover: null,
        dragging: false,
        dragMoved: false,
        additiveDrag: false,
        startX: 0,
        startY: 0,
        annotating: false,
        suppressHover: false
      };

      /// Interactive picker chrome only (chip + input). Highlight boxes are
      /// pointer-events:none and must NOT count — clicks pass through them.
      function isUI(el) {
        if (!el) { return false; }
        if (el.nodeType === 3) { el = el.parentElement; }
        if (!el) { return false; }
        if (el === chip || el === input || el === marquee) { return true; }
        try {
          if (chip.contains(el)) { return true; }
        } catch (e) {}
        return false;
      }

      /// True when this pointer/keyboard event is aimed at the type chip.
      function eventIsUI(e) {
        if (!e) { return false; }
        try {
          var path = typeof e.composedPath === 'function' ? e.composedPath() : null;
          if (path && path.length) {
            for (var i = 0; i < path.length; i++) {
              var n = path[i];
              if (n === chip || n === input || n === marquee) { return true; }
              if (n && chip.contains && n.nodeType === 1 && chip.contains(n)) { return true; }
            }
          }
        } catch (err) {}
        return isUI(e.target);
      }

      function uiShow(el) {
        if (!el) { return; }
        el.style.display = 'block';
      }

      function uiHide(el) {
        if (!el) { return; }
        el.style.display = 'none';
      }

      function focusInput() {
        try {
          if (typeof input.focus === 'function') {
            input.focus({ preventScroll: true });
          }
        } catch (e) {
          try { input.focus(); } catch (e2) {}
        }
      }

      /// Viewport → layer-local coords. getBoundingClientRect is always viewport;
      /// our chrome is position:absolute inside the fixed layer, which may itself
      /// sit inside a transformed dialog (fixed containing block ≠ viewport).
      function layerRect() {
        try {
          return layer.getBoundingClientRect();
        } catch (e) {
          return { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 };
        }
      }

      /// Keep the overlay layer in the same host as the selection. Open <dialog>
      /// elements live in the top layer — the layer must be inside them to paint
      /// above modal content.
      function mountLayer(nearEl) {
        if (!document.body) { return; }
        var host = document.body;
        if (nearEl) {
          var modal = closestModal(nearEl);
          if (modal) { host = modal; }
        }
        if (layer.parentElement !== host) {
          try { host.appendChild(layer); } catch (e) {
            if (layer.parentElement !== document.body) {
              document.body.appendChild(layer);
            }
          }
        }
        if (marquee.parentElement !== layer) { layer.appendChild(marquee); }
        if (chip.parentElement !== layer) { layer.appendChild(chip); }
        boxPool.forEach(function (b) {
          if (b.parentElement !== layer) { layer.appendChild(b); }
        });
      }

      function isVisibleBox(el) {
        if (!el || !el.getBoundingClientRect) { return false; }
        try {
          var r = el.getBoundingClientRect();
          if (r.width < 2 || r.height < 2) { return false; }
          var cs = window.getComputedStyle(el);
          if (cs.display === 'none' || cs.visibility === 'hidden' || cs.opacity === '0') {
            return false;
          }
          return true;
        } catch (e) { return false; }
      }

      /// Closest *open, visible* modal / drawer / sheet. Never return a closed
      /// or display:none dialog — mounting the chip there hides it entirely.
      function closestModal(el) {
        if (!el || !el.closest) { return null; }
        try {
          var d = el.closest('dialog[open]');
          if (d && isVisibleBox(d)) { return d; }
        } catch (e) {}
        var n = el;
        while (n && n !== document.body && n !== document.documentElement) {
          if (n.getAttribute) {
            var state = n.getAttribute('data-state');
            var role = (n.getAttribute('role') || '').toLowerCase();
            var cls = (typeof n.className === 'string' ? n.className : '').toLowerCase();
            var ariaModal = n.getAttribute('aria-modal') === 'true';
            var isDialogRole = role === 'dialog' || role === 'alertdialog' || ariaModal;
            var looksLikeOverlay = /\b(drawer|sheet|modal|dialog)\b/.test(cls);
            var openish = state === 'open' || n.hasAttribute('data-open')
              || (n.tagName === 'DIALOG' && (n.open || n.hasAttribute('open')));
            // Require an open signal — bare role=dialog matches closed portals.
            if ((isDialogRole || looksLikeOverlay) && openish && isVisibleBox(n)) {
              return n;
            }
          }
          n = n.parentElement;
        }
        return null;
      }

      function isBackdrop(el) {
        if (!el || el === document.body || el === document.documentElement) { return false; }
        if (isUI(el)) { return false; }
        var role = (el.getAttribute('role') || '').toLowerCase();
        if (role === 'presentation' || role === 'none') { return true; }
        var cls = (typeof el.className === 'string' ? el.className : '').toLowerCase();
        if (/\b(backdrop|overlay|scrim|underlay)\b/.test(cls)) { return true; }
        if (el.hasAttribute('data-aria-hidden') || el.getAttribute('aria-hidden') === 'true') {
          var r0 = el.getBoundingClientRect();
          if (r0.width > window.innerWidth * 0.85 && r0.height > window.innerHeight * 0.85) {
            return true;
          }
        }
        try {
          var r = el.getBoundingClientRect();
          if (r.width < window.innerWidth * 0.9 || r.height < window.innerHeight * 0.9) {
            return false;
          }
          var cs = window.getComputedStyle(el);
          if (cs.pointerEvents === 'none') { return true; }
          // Full-viewport dim layer with no meaningful text.
          var text = (el.innerText || '').trim();
          if (text.length < 2 && el.children.length <= 2) {
            var bg = cs.backgroundColor || '';
            if (/rgba?\(\s*\d+,\s*\d+,\s*\d+,\s*0?\.?[0-8]/.test(bg) || bg === 'transparent') {
              return true;
            }
          }
        } catch (e) {}
        return false;
      }

      function isInteractive(el) {
        if (!el || el.nodeType !== 1) { return false; }
        var tag = el.tagName;
        if (/^(A|BUTTON|INPUT|SELECT|TEXTAREA|LABEL|SUMMARY|OPTION)$/i.test(tag)) { return true; }
        var role = (el.getAttribute('role') || '').toLowerCase();
        if (/^(button|link|checkbox|radio|tab|menuitem|option|switch|textbox|combobox|slider|spinbutton|searchbox)$/.test(role)) {
          return true;
        }
        if (el.hasAttribute('contenteditable') && el.getAttribute('contenteditable') !== 'false') {
          return true;
        }
        if (el.hasAttribute('tabindex') && el.getAttribute('tabindex') !== '-1') { return true; }
        if (typeof el.onclick === 'function') { return true; }
        return false;
      }

      function isTrivialLeaf(el) {
        if (!el) { return true; }
        if (isInteractive(el)) { return false; }
        var tag = el.tagName;
        if (/^(SVG|PATH|I|BR|HR|WBR|USE|CIRCLE|RECT|LINE|POLYLINE|POLYGON)$/i.test(tag)) {
          return true;
        }
        var r = el.getBoundingClientRect();
        if (r.width > 0 && r.height > 0 && r.width < 28 && r.height < 28) { return true; }
        // Tiny text wrappers inside buttons/links.
        if (/^(SPAN|STRONG|EM|B|SMALL|TIME|SVG)$/i.test(tag)) {
          var t = (el.innerText || el.textContent || '').trim();
          if (t.length < 48) { return true; }
        }
        return false;
      }

      function ensureStyle() {
        if (document.getElementById(HL_STYLE_ID)) { return; }
        var s = document.createElement('style');
        s.id = HL_STYLE_ID;
        s.setAttribute('data-agentide-ui', '1');
        s.textContent =
          '.' + HL_CLASS + '{' +
          'outline:2px solid #007AFF !important;' +
          'outline-offset:2px !important;' +
          'box-shadow:0 0 0 4px rgba(0,122,255,0.22) !important;' +
          'border-radius:3px;' +
          '}';
        (document.head || document.documentElement).appendChild(s);
      }

      function ensureMounted() {
        if (!document.body) { return; }
        ensureStyle();
        mountLayer(state.selected[0] || state.hover || null);
      }

      function acquireBox() {
        for (var i = 0; i < boxPool.length; i++) {
          if (boxPool[i].style.display === 'none') { return boxPool[i]; }
        }
        var b = document.createElement('div');
        b.setAttribute('data-agentide-ui', '1');
        b.style.cssText = HIGHLIGHT;
        boxPool.push(b);
        ensureMounted();
        layer.appendChild(b);
        return b;
      }

      function hideAllBoxes() {
        boxPool.forEach(function (b) { uiHide(b); });
      }

      function clearElementOutlines() {
        try {
          document.querySelectorAll('.' + HL_CLASS).forEach(function (el) {
            el.classList.remove(HL_CLASS);
          });
        } catch (e) {}
      }

      function placeBox(box, el) {
        if (!el || !el.getBoundingClientRect) {
          uiHide(box);
          return;
        }
        var r = el.getBoundingClientRect();
        if (r.width < 1 || r.height < 1) {
          uiHide(box);
          return;
        }
        mountLayer(el);
        if (box.parentElement !== layer) { layer.appendChild(box); }
        var lr = layerRect();
        box.style.left = Math.round(r.left - lr.left) + 'px';
        box.style.top = Math.round(r.top - lr.top) + 'px';
        box.style.width = Math.max(0, Math.round(r.width)) + 'px';
        box.style.height = Math.max(0, Math.round(r.height)) + 'px';
        uiShow(box);
      }

      function paintSelection() {
        ensureMounted();
        hideAllBoxes();
        clearElementOutlines();
        var list = state.selected.length ? state.selected
          : (state.hover && !state.annotating ? [state.hover] : []);
        list.forEach(function (el) {
          if (!el || !el.isConnected) { return; }
          placeBox(acquireBox(), el);
          try { el.classList.add(HL_CLASS); } catch (e) {}
        });
      }

      function cssPath(el) {
        if (el.id) { return '#' + CSS.escape(el.id); }
        var parts = [];
        var node = el;
        while (node && node.nodeType === 1 && node !== document.body && parts.length < 5) {
          if (node.id) { parts.unshift('#' + CSS.escape(node.id)); break; }
          var part = node.tagName.toLowerCase();
          var cls = (typeof node.className === 'string' ? node.className : '')
            .trim().split(/\s+/).filter(function (c) {
              return c && c !== HL_CLASS && c.indexOf('agentide') !== 0;
            }).slice(0, 2);
          if (cls.length) { part += '.' + cls.map(CSS.escape).join('.'); }
          var parent = node.parentElement;
          if (parent) {
            var sibs = Array.prototype.filter.call(parent.children, function (c) {
              return c.tagName === node.tagName;
            });
            if (sibs.length > 1) { part += ':nth-of-type(' + (sibs.indexOf(node) + 1) + ')'; }
          }
          parts.unshift(part);
          node = parent;
        }
        return parts.join(' > ');
      }

      function hideMarquee() {
        uiHide(marquee);
      }

      function updateMarquee(x1, y1, x2, y2) {
        ensureMounted();
        // x1/y1 are client (viewport) coords — keep viewport rect for hit tests,
        // only convert when painting into the layer.
        var left = Math.min(x1, x2);
        var top = Math.min(y1, y2);
        var w = Math.abs(x2 - x1);
        var h = Math.abs(y2 - y1);
        var lr = layerRect();
        marquee.style.left = Math.round(left - lr.left) + 'px';
        marquee.style.top = Math.round(top - lr.top) + 'px';
        marquee.style.width = w + 'px';
        marquee.style.height = h + 'px';
        uiShow(marquee);
        return { left: left, top: top, right: left + w, bottom: top + h, width: w, height: h };
      }

      function rectOverlap(a, b) {
        var x = Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left));
        var y = Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
        return x * y;
      }

      function elArea(el) {
        var r = el.getBoundingClientRect();
        return Math.max(0, r.width) * Math.max(0, r.height);
      }

      /// Prefer "component-sized" nodes: interactive tags, roles, cards, mid blocks.
      function isComponentCandidate(el) {
        if (!el || el === document.body || el === document.documentElement) { return false; }
        if (isUI(el) || isBackdrop(el)) { return false; }
        var tag = el.tagName;
        if (/^(SCRIPT|STYLE|META|LINK|BR|HR|NOSCRIPT|SVG|PATH|HEAD|HTML)$/i.test(tag)) { return false; }
        var r = el.getBoundingClientRect();
        if (r.width < 8 || r.height < 8) { return false; }
        // Skip near-viewport wrappers (page shells) — but allow modal panels.
        var inModal = !!closestModal(el);
        if (!inModal && r.width > window.innerWidth * 0.92 && r.height > window.innerHeight * 0.55) {
          return false;
        }
        // Inside a modal, still skip the full-bleed shell of the dialog itself
        // when it's essentially the viewport (user wants content inside).
        if (inModal && el === closestModal(el)
            && r.width > window.innerWidth * 0.96 && r.height > window.innerHeight * 0.9) {
          return false;
        }
        var role = (el.getAttribute('role') || '').toLowerCase();
        var cls = (typeof el.className === 'string' ? el.className : '').toLowerCase();
        if (isInteractive(el)) { return true; }
        if (/^(IMG|VIDEO|CANVAS|PICTURE)$/i.test(tag)) { return true; }
        if (/^(listitem|article|card|group|region|heading)$/.test(role)) { return true; }
        if (/^(LI|ARTICLE|SECTION|ASIDE|FIGURE|FIELDSET|TR|TD|TH|HEADER|FOOTER|NAV|MAIN|FORM|UL|OL|DL|H1|H2|H3|H4|H5|H6|P)$/i.test(tag)) {
          return true;
        }
        // Common component class hints (cards, tiles, rows, items).
        if (/\b(card|tile|item|row|cell|panel|widget|product|post|entry|box|col|column|grid-item|menu-item|list-item)\b/.test(cls)) {
          return true;
        }
        if (r.width >= 36 && r.height >= 20 && r.width * r.height >= 900) { return true; }
        return false;
      }

      /// Score for multi-select peer grouping only — not used to inflate
      /// single-click parents over precise interactive targets.
      function componentScore(el) {
        var r = el.getBoundingClientRect();
        var area = r.width * r.height;
        var vp = window.innerWidth * window.innerHeight;
        var score = 0;
        var tag = el.tagName;
        var role = (el.getAttribute('role') || '').toLowerCase();
        var cls = (typeof el.className === 'string' ? el.className : '').toLowerCase();
        if (isInteractive(el)) { score += 6; }
        if (/^(LI|ARTICLE|FIGURE|A|BUTTON|IMG|TR|H1|H2|H3)$/i.test(tag)) { score += 3; }
        if (/listitem|article|card|button|link/.test(role)) { score += 3; }
        if (/\b(card|tile|item|row|product|post|entry|grid-item)\b/.test(cls)) { score += 4; }
        // Prefer mid-size peers (cards), not tiny icons or giant sections.
        var frac = area / Math.max(1, vp);
        if (frac > 0.001 && frac < 0.18) { score += 3; }
        else if (frac >= 0.18) { score -= 3; }
        var ar = r.width / Math.max(1, r.height);
        if (ar > 0.35 && ar < 8) { score += 1; }
        var p = el.parentElement;
        if (p) {
          try {
            var cs = window.getComputedStyle(p);
            if (cs.display === 'flex' || cs.display === 'grid'
                || cs.display === 'inline-flex' || cs.display === 'inline-grid') {
              score += 2;
            }
          } catch (e) {}
        }
        return score;
      }

      /// Collapse nested hits into a peer group: prefer similar siblings
      /// (cards in a row) over deepest leaves or a giant shared parent.
      function groupComponents(els) {
        if (!els || !els.length) { return []; }
        // Dedupe
        var uniq = [];
        els.forEach(function (el) {
          if (el && uniq.indexOf(el) < 0) { uniq.push(el); }
        });
        if (uniq.length === 1) { return uniq; }

        // Cluster by parent — keep the densest sibling group with similar area.
        var byParent = new Map();
        uniq.forEach(function (el) {
          var p = el.parentElement || document.body;
          if (!byParent.has(p)) { byParent.set(p, []); }
          byParent.get(p).push(el);
        });
        var bestGroup = null;
        var bestKey = -1;
        byParent.forEach(function (group) {
          if (group.length < 2) { return; }
          var areas = group.map(elArea).sort(function (a, b) { return a - b; });
          var med = areas[Math.floor(areas.length / 2)] || 1;
          var peers = group.filter(function (el) {
            var a = elArea(el);
            return a > med * 0.25 && a < med * 4;
          });
          if (peers.length < 2) { return; }
          var scoreSum = peers.reduce(function (s, el) { return s + componentScore(el); }, 0);
          var key = peers.length * 10 + scoreSum;
          if (key > bestKey) {
            bestKey = key;
            bestGroup = peers;
          }
        });
        if (bestGroup && bestGroup.length >= 2) {
          return bestGroup.slice(0, MAX_SELECT);
        }

        // No clear sibling set: among containment chains, keep the best-scoring
        // node in each chain (mid-level card, not every nested button).
        var scored = uniq.map(function (el) {
          return { el: el, score: componentScore(el), area: elArea(el) };
        });
        scored.sort(function (a, b) { return b.score - a.score || a.area - b.area; });
        var kept = [];
        scored.forEach(function (item) {
          var el = item.el;
          var dominated = kept.some(function (k) {
            return k !== el && (k.contains(el) || el.contains(k));
          });
          if (dominated) {
            // Replace a kept ancestor/descendant if this one scores better
            // and is a tighter peer size.
            for (var i = 0; i < kept.length; i++) {
              var k = kept[i];
              if (k === el) { return; }
              if (k.contains(el) || el.contains(k)) {
                var ks = componentScore(k);
                if (item.score > ks || (item.score === ks && item.area < elArea(k))) {
                  kept[i] = el;
                }
                return;
              }
            }
            return;
          }
          kept.push(el);
        });
        // Final pass: drop pure nesting leftovers (keep outer when nested pair remains).
        kept = kept.filter(function (el) {
          return !kept.some(function (other) {
            return other !== el && other.contains(el) && componentScore(other) >= componentScore(el);
          });
        });
        return kept.slice(0, MAX_SELECT);
      }

      var MAX_SELECT = 24;

      function pickManyFromMarquee(m) {
        var mx = (m.left + m.right) / 2;
        var my = (m.top + m.bottom) / 2;
        var marqueeArea = Math.max(1, m.width * m.height);
        // Small drag → single precise pick (don't expand to surrounding cards).
        if (m.width < 28 && m.height < 28) {
          var one = pickDeepestAt(mx, my);
          return one ? [one] : [];
        }

        var scopeRoot = null;
        var scopeHit = pickDeepestAt(mx, my);
        if (scopeHit) { scopeRoot = closestModal(scopeHit); }

        var hits = [];
        var all = document.body ? document.body.querySelectorAll('*') : [];
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          if (scopeRoot && !scopeRoot.contains(el)) { continue; }
          if (!isComponentCandidate(el)) { continue; }
          var r = el.getBoundingClientRect();
          var er = { left: r.left, top: r.top, right: r.right, bottom: r.bottom };
          var cx = (er.left + er.right) / 2;
          var cy = (er.top + er.bottom) / 2;
          var centerIn = cx >= m.left && cx <= m.right && cy >= m.top && cy <= m.bottom;
          var overlap = rectOverlap(m, er);
          if (overlap <= 0 && !centerIn) { continue; }
          var area = r.width * r.height;
          if (area <= 0) { continue; }
          // Element much larger than marquee is usually a container swallowing the drag.
          if (area > marqueeArea * 6 && !isInteractive(el)) { continue; }
          var inside = overlap / area;
          var covers = overlap / marqueeArea;
          if (!centerIn && inside < 0.35 && covers < 0.08) { continue; }
          var score = (centerIn ? 3 : 0) + inside * 2 + covers
            + (isInteractive(el) ? 2 : 0) + componentScore(el) * 0.1;
          // Prefer elements similar in size to the marquee for single-component drags.
          var sizeRatio = area / marqueeArea;
          if (sizeRatio > 0.25 && sizeRatio < 4) { score += 1.5; }
          hits.push({ el: el, score: score, area: area });
        }
        hits.sort(function (a, b) { return b.score - a.score || a.area - b.area; });

        // Medium marquee: if one interactive/tight hit dominates, keep just that.
        if (marqueeArea < 90000 && hits.length) {
          var top = hits[0];
          var peers = hits.filter(function (h) {
            if (h.el === top.el) { return true; }
            var ar = h.area / Math.max(1, top.area);
            return ar > 0.45 && ar < 2.2 && Math.abs(h.score - top.score) < 2.5;
          });
          if (peers.length < 2) {
            // Prefer interactive under the marquee when only one solid hit.
            for (var j = 0; j < Math.min(hits.length, 8); j++) {
              if (isInteractive(hits[j].el)) { return [hits[j].el]; }
            }
            return [top.el];
          }
        }

        var els = hits.slice(0, 80).map(function (h) { return h.el; });
        els = groupComponents(els);
        if (!els.length) {
          var hit = pickDeepestAt(mx, my);
          if (hit) { els = [hit]; }
        }
        return els.slice(0, MAX_SELECT);
      }

      /// Topmost non-UI, non-backdrop element under the cursor.
      function rawHitAt(x, y) {
        var stack = [];
        try {
          if (document.elementsFromPoint) {
            stack = document.elementsFromPoint(x, y) || [];
          }
        } catch (e) {}
        if (!stack.length) {
          var one = document.elementFromPoint(x, y);
          if (one) { stack = [one]; }
        }
        for (var i = 0; i < stack.length; i++) {
          var el = stack[i];
          if (!el || !(el instanceof Element)) { continue; }
          if (isUI(el)) { continue; }
          if (isBackdrop(el)) { continue; }
          return el;
        }
        return null;
      }

      /// Single-click / hover: prefer the precise interactive target, not the
      /// parent card. Only climb for trivial leaves (icons, bare text spans).
      function pickDeepestAt(x, y) {
        var hit = rawHitAt(x, y);
        if (!hit) { return null; }

        var modal = closestModal(hit);
        // Climb past our own outline paint targets if any slipped through.
        var node = hit;
        while (node && isUI(node)) { node = node.parentElement; }
        if (!node || !(node instanceof Element)) { return null; }

        // Deepest interactive ancestor within the modal/page.
        var n = node;
        var interactive = null;
        var candidates = [];
        while (n && n !== document.body && n !== document.documentElement) {
          if (modal && n !== modal && !modal.contains(n)) { break; }
          if (isComponentCandidate(n)) { candidates.push(n); }
          if (!interactive && isInteractive(n)) { interactive = n; }
          // Stop at modal root — don't select the whole page behind a drawer.
          if (modal && n === modal) { break; }
          n = n.parentElement;
        }

        if (interactive) {
          // Use the interactive control itself (button/link/input), not its card.
          return interactive;
        }

        // No interactive control: climb only while the leaf is trivial, and
        // keep the tightest useful block (never jump to a much larger card).
        var best = node;
        if (candidates.length) {
          best = candidates[0];
          var bestArea = elArea(best);
          for (var i = 1; i < Math.min(candidates.length, 8); i++) {
            // Stop as soon as we have a non-trivial target — do not promote
            // a button-sized block up to its parent card.
            if (!isTrivialLeaf(best)) { break; }
            var c = candidates[i];
            var a = elArea(c);
            // Allow a modest climb for icon/span → labeled control wrapper.
            if (a < Math.max(bestArea * 12, 4000)
                && a < window.innerWidth * window.innerHeight * 0.15) {
              best = c;
              bestArea = a;
              continue;
            }
            break;
          }
        } else {
          while (best && isTrivialLeaf(best) && best.parentElement
                 && best.parentElement !== document.body) {
            if (modal && !modal.contains(best.parentElement)
                && best.parentElement !== modal) { break; }
            best = best.parentElement;
            if (isComponentCandidate(best)) { break; }
          }
        }
        return best instanceof Element ? best : hit;
      }

      function hideChip() {
        uiHide(chip);
        input.value = '';
        state.annotating = false;
      }

      function updateHint() {
        var n = state.selected.length;
        if (n <= 1) {
          hint.textContent = 'Annotate · Enter sends & exits · Esc clears · ⇧/⌘-click or ⇧-drag groups';
        } else {
          hint.textContent = n + ' components grouped · Enter sends & exits · Esc clears · ⇧/⌘ toggles';
        }
      }

      function showChip() {
        if (!state.selected.length) { hideChip(); return; }
        ensureMounted();
        state.annotating = true;
        state.hover = null;
        paintSelection();
        updateHint();
        var left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
        var anchor = state.selected[0];
        state.selected.forEach(function (el) {
          if (!el.getBoundingClientRect) { return; }
          var r = el.getBoundingClientRect();
          left = Math.min(left, r.left);
          top = Math.min(top, r.top);
          right = Math.max(right, r.right);
          bottom = Math.max(bottom, r.bottom);
        });
        if (!isFinite(left)) { left = 16; top = 16; right = 16; bottom = 16; }
        mountLayer(anchor);
        var lr = layerRect();
        var chipW = 300;
        // Clamp within the layer (viewport or modal), then convert to layer-local.
        var viewW = lr.width || window.innerWidth;
        var viewH = lr.height || window.innerHeight;
        var cLeftVp = Math.min(Math.max(lr.left + 8, left), lr.left + viewW - chipW - 8);
        var cTopVp = bottom + 8;
        if (cTopVp + 64 > lr.top + viewH) {
          cTopVp = Math.max(lr.top + 8, top - 64);
        }
        chip.setAttribute('data-agentide-chip', '1');
        chip.style.left = Math.round(cLeftVp - lr.left) + 'px';
        chip.style.top = Math.round(cTopVp - lr.top) + 'px';
        chip.style.width = chipW + 'px';
        chip.style.pointerEvents = 'auto';
        input.style.pointerEvents = 'auto';
        uiShow(chip);
        // Defer past the mouseup/click that opened us — preventDefault on the
        // pick can otherwise leave the field unfocused in WKWebView.
        setTimeout(function () {
          focusInput();
          try { input.select(); } catch (e) {}
        }, 0);
        setTimeout(focusInput, 50);
      }

      function setSelection(els, openChip) {
        var seen = [];
        (els || []).forEach(function (el) {
          if (el && el.isConnected && seen.indexOf(el) < 0) { seen.push(el); }
        });
        state.selected = seen.slice(0, MAX_SELECT);
        state.hover = null;
        paintSelection();
        if (openChip && state.selected.length) { showChip(); }
        else if (!state.selected.length) { hideChip(); }
      }

      function mergeSelection(els, openChip) {
        var merged = state.selected.slice();
        (els || []).forEach(function (el) {
          if (el && merged.indexOf(el) < 0) { merged.push(el); }
        });
        setSelection(groupComponents(merged), openChip);
      }

      function toggleInSelection(el) {
        if (!el) { return; }
        var idx = state.selected.indexOf(el);
        if (idx >= 0) {
          state.selected.splice(idx, 1);
        } else if (state.selected.length < MAX_SELECT) {
          state.selected.push(el);
        }
        state.hover = null;
        // Re-group if nested pairs appear.
        state.selected = groupComponents(state.selected);
        paintSelection();
        if (state.selected.length) { showChip(); }
        else { hideChip(); }
      }

      function clearSelection() {
        hideChip();
        hideMarquee();
        hideAllBoxes();
        clearElementOutlines();
        state.selected = [];
        state.hover = null;
        state.dragging = false;
        state.dragMoved = false;
        state.additiveDrag = false;
        state.suppressHover = true;
      }

      function submitAnnotation() {
        if (!state.selected.length) { return; }
        var note = (input.value || '').trim();
        if (!note) { return; }
        var els = state.selected.slice();
        var selectors = els.map(cssPath);
        var texts = els.map(function (el) {
          return (el.innerText || el.value || el.alt || '').trim().replace(/\s+/g, ' ').slice(0, 80);
        }).filter(Boolean);
        var htmls = els.slice(0, 4).map(function (el) {
          return el.outerHTML.replace(/\s+/g, ' ').slice(0, 200);
        });
        window.webkit.messageHandlers.agentidePicker.postMessage({
          action: 'annotate',
          selectors: selectors,
          selector: selectors[0] || '',
          text: texts.slice(0, 3).join(' · ').slice(0, 160),
          html: htmls.join(' || ').slice(0, 600),
          note: note
        });
        // Clear local UI immediately; Swift sets pickerActive = false.
        clearSelection();
        state.active = false;
        document.documentElement.style.cursor = '';
      }

      function onMove(e) {
        if (!state.active) { return; }
        if (eventIsUI(e)) { return; }
        if (state.dragging) {
          var dx = e.clientX - state.startX;
          var dy = e.clientY - state.startY;
          if (Math.abs(dx) > 4 || Math.abs(dy) > 4) { state.dragMoved = true; }
          if (state.dragMoved) {
            var m = updateMarquee(state.startX, state.startY, e.clientX, e.clientY);
            var preview = pickManyFromMarquee(m);
            if (state.additiveDrag && state.selected.length) {
              // Show union preview while additive-dragging.
              var union = state.selected.slice();
              preview.forEach(function (el) {
                if (union.indexOf(el) < 0) { union.push(el); }
              });
              preview = groupComponents(union);
            }
            // Live highlight without opening chip mid-drag.
            hideAllBoxes();
            clearElementOutlines();
            preview.forEach(function (el) {
              placeBox(acquireBox(), el);
              try { el.classList.add(HL_CLASS); } catch (err) {}
            });
            // Don't clobber committed selection until mouseup when additive.
            if (!state.additiveDrag) {
              state.selected = preview;
            } else {
              state._marqueePreview = preview;
            }
          }
          return;
        }
        if (state.annotating || state.suppressHover) { return; }
        var el = pickDeepestAt(e.clientX, e.clientY);
        state.hover = el;
        if (!state.selected.length) { paintSelection(); }
      }

      function onDown(e) {
        if (!state.active || e.button !== 0) { return; }
        // Clicking the type box: do not start a pick / steal the event from the input.
        if (eventIsUI(e)) {
          state.dragging = false;
          state.dragMoved = false;
          return;
        }
        state.suppressHover = false;
        var additive = e.shiftKey || e.metaKey || e.ctrlKey;
        // Additive click (no drag intent yet): toggle into selection.
        // Still allow ⇧-drag by starting marquee when movement exceeds threshold.
        state.additiveDrag = additive;
        if (state.annotating && !additive) { hideChip(); }
        state.dragging = true;
        state.dragMoved = false;
        state.startX = e.clientX;
        state.startY = e.clientY;
        state._marqueePreview = null;
        e.preventDefault();
        e.stopPropagation();
      }

      function onUp(e) {
        if (!state.active) { return; }
        // Released on the chip — cancel any in-progress pick, keep selection.
        if (eventIsUI(e)) {
          state.dragging = false;
          state.dragMoved = false;
          state.additiveDrag = false;
          hideMarquee();
          return;
        }
        if (!state.dragging) { return; }
        state.dragging = false;
        e.preventDefault();
        e.stopPropagation();

        var additive = state.additiveDrag || e.shiftKey || e.metaKey || e.ctrlKey;
        state.additiveDrag = false;

        if (state.dragMoved) {
          var m = {
            left: Math.min(state.startX, e.clientX),
            top: Math.min(state.startY, e.clientY),
            right: Math.max(state.startX, e.clientX),
            bottom: Math.max(state.startY, e.clientY),
            width: Math.abs(e.clientX - state.startX),
            height: Math.abs(e.clientY - state.startY)
          };
          hideMarquee();
          var picked = state._marqueePreview || pickManyFromMarquee(m);
          state._marqueePreview = null;
          if (additive) { mergeSelection(picked, true); }
          else { setSelection(picked, true); }
        } else {
          hideMarquee();
          var hit = pickDeepestAt(e.clientX, e.clientY);
          if (additive) {
            if (hit) { toggleInSelection(hit); }
          } else if (hit) {
            setSelection([hit], true);
          } else {
            setSelection([], false);
          }
        }
      }

      function onClick(e) {
        if (!state.active) { return; }
        // Let the input receive click/focus; block page navigation under picks.
        if (eventIsUI(e)) { return; }
        e.preventDefault();
        e.stopPropagation();
      }

      function onKey(e) {
        if (!state.active) { return; }
        // While typing in the chip, only handle Enter/Esc — never swallow keys.
        var inChip = eventIsUI(e) || document.activeElement === input;
        if (e.key === 'Escape') {
          if (state.annotating || state.selected.length || state.hover) {
            e.preventDefault();
            e.stopPropagation();
            clearSelection();
          } else {
            // Second Esc (nothing selected) exits annotate mode via host.
            window.webkit.messageHandlers.agentidePicker.postMessage({ action: 'cancel' });
            state.active = false;
            document.documentElement.style.cursor = '';
          }
          return;
        }
        if (e.key === 'Enter' && state.annotating && (document.activeElement === input || inChip)) {
          e.preventDefault();
          e.stopPropagation();
          submitAnnotation();
          return;
        }
        if (inChip) { return; }
      }

      // Chip bubble listeners only — capture would stopPropagation before the
      // input receives the event and break focus/typing.
      chip.addEventListener('pointerdown', function (e) {
        e.stopPropagation();
      });
      chip.addEventListener('mousedown', function (e) {
        e.stopPropagation();
        if (e.target !== input) { focusInput(); }
      });
      chip.addEventListener('mouseup', function (e) {
        e.stopPropagation();
      });
      chip.addEventListener('click', function (e) {
        e.stopPropagation();
      });

      input.addEventListener('keydown', function (e) {
        e.stopPropagation();
        if (e.key === 'Enter') {
          e.preventDefault();
          submitAnnotation();
        } else if (e.key === 'Escape') {
          e.preventDefault();
          clearSelection();
        }
      });
      input.addEventListener('keyup', function (e) { e.stopPropagation(); });
      input.addEventListener('keypress', function (e) { e.stopPropagation(); });

      function onScrollOrResize() {
        if (state.active && (state.selected.length || state.hover || state.annotating)) {
          paintSelection();
          if (state.annotating && state.selected.length) { showChip(); }
        }
      }

      window.__agentidePicker = {
        version: 4,
        setActive: function (on) {
          state.active = !!on;
          document.documentElement.style.cursor = on ? 'crosshair' : '';
          if (!on) { clearSelection(); }
          else { ensureMounted(); state.suppressHover = false; paintSelection(); }
        },
        clear: function () { clearSelection(); },
        destroy: function () {
          state.active = false;
          clearSelection();
          document.documentElement.style.cursor = '';
          try {
            document.removeEventListener('mousemove', onMove, true);
            document.removeEventListener('mousedown', onDown, true);
            document.removeEventListener('mouseup', onUp, true);
            document.removeEventListener('click', onClick, true);
            document.removeEventListener('keydown', onKey, true);
            window.removeEventListener('scroll', onScrollOrResize, true);
            window.removeEventListener('resize', onScrollOrResize, true);
          } catch (e) {}
          try {
            if (layer && layer.parentNode) { layer.parentNode.removeChild(layer); }
            var st = document.getElementById(HL_STYLE_ID);
            if (st && st.parentNode) { st.parentNode.removeChild(st); }
          } catch (e) {}
          boxPool = [];
          window.__agentidePicker = null;
        }
      };

      document.addEventListener('mousemove', onMove, true);
      document.addEventListener('mousedown', onDown, true);
      document.addEventListener('mouseup', onUp, true);
      document.addEventListener('click', onClick, true);
      document.addEventListener('keydown', onKey, true);
      window.addEventListener('scroll', onScrollOrResize, true);
      window.addEventListener('resize', onScrollOrResize, true);
    })();
    """#

    /// Page snapshot: title/url, up to 80 visible interactive elements with
    /// short CSS selectors + labels, then trimmed body text.
    /// Ring buffer of console output (error/warn/log/info) + uncaught
    /// exceptions + unhandled promise rejections + failed fetch/XHR requests
    /// (network failure or 4xx/5xx status). Injected at document start so
    /// early boot errors (e.g. a crashing framework bundle) are caught too.
    private static let consoleCaptureJS = #"""
    (function () {
      if (window.__agentideLogs) { return; }
      var logs = [];
      window.__agentideLogs = logs;
      // ponytail: one ring buffer for everything; split error/log buffers
      // if a log-spammy app ever evicts the errors an agent is hunting.
      function push(kind, msg) {
        if (logs.length >= 500) { logs.shift(); }
        logs.push(kind + ': ' + msg);
      }
      ['error', 'warn', 'log', 'info'].forEach(function (kind) {
        var orig = console[kind];
        console[kind] = function () {
          try {
            push(kind, Array.prototype.map.call(arguments, function (a) {
              if (typeof a === 'string') { return a; }
              try { return JSON.stringify(a); } catch (e) { return String(a); }
            }).join(' '));
          } catch (e) {}
          return orig.apply(console, arguments);
        };
      });
      window.addEventListener('error', function (e) {
        push('uncaught', (e.message || 'error') + ' @ ' +
             (e.filename || '?') + ':' + (e.lineno || 0));
      });
      window.addEventListener('unhandledrejection', function (e) {
        var r = e.reason;
        push('unhandledrejection', (r && (r.stack || r.message)) || String(r));
      });
      var origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function () {
          var url = arguments[0] && (arguments[0].url || String(arguments[0]));
          return origFetch.apply(this, arguments).then(function (res) {
            if (!res.ok) { push('http', res.status + ' ' + (res.url || url)); }
            return res;
          }, function (err) {
            push('network', ((err && err.message) || String(err)) + ' — ' + url);
            throw err;
          });
        };
      }
      var origXHROpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__agentideURL = url;
        return origXHROpen.apply(this, arguments);
      };
      var origXHRSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function () {
        var xhr = this;
        xhr.addEventListener('loadend', function () {
          if (xhr.status === 0) { push('network', 'failed — ' + xhr.__agentideURL); }
          else if (xhr.status >= 400) { push('http', xhr.status + ' ' + xhr.__agentideURL); }
        });
        return origXHRSend.apply(this, arguments);
      };
    })();
    """#

    private static let snapshotJS = #"""
    (function () {
      var out = ['title: ' + document.title, 'url: ' + location.href, ''];
      function sel(el) {
        if (el.id) { return '#' + el.id; }
        var s = el.tagName.toLowerCase();
        var cls = (typeof el.className === 'string' ? el.className : '')
          .trim().split(/\s+/).filter(Boolean).slice(0, 2);
        if (cls.length) { s += '.' + cls.join('.'); }
        return s;
      }
      var items = [];
      var els = document.querySelectorAll('a[href],button,input,select,textarea,[role="button"]');
      for (var i = 0; i < els.length && items.length < 80; i++) {
        var el = els[i];
        var r = el.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) { continue; }
        var label = (el.innerText || el.value || el.placeholder ||
                     el.getAttribute('aria-label') || '')
          .trim().replace(/\s+/g, ' ').slice(0, 60);
        items.push(sel(el) + (label ? ' "' + label + '"' : ''));
      }
      out.push('interactive (' + items.length + '):');
      out = out.concat(items);
      out.push('', 'text:',
        document.body.innerText.replace(/\n{3,}/g, '\n\n').slice(0, 4000));
      return out.join('\n');
    })();
    """#
}

/// Breaks the WKUserContentController → handler → webView retain cycle.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
