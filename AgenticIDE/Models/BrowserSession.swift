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
    /// a pane makes the edge bar appear; it never auto-expands browser mode —
    /// the user chooses when to look. A nil url opens the blank start page.
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

    /// Expand browser mode (⌘B when collapsed). Reuses an existing pane or
    /// opens one for the active workspace when it prefers the browser.
    func expandMode(projectSession: ProjectSession?) {
        if !sessions.isEmpty {
            setModeActive(true)
            return
        }
        if let projectSession, let ws = projectSession.activeWorkspace {
            openManual(from: ws, projectSession: projectSession)
        }
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
/// aspect-fit it into the card via WKWebView magnification, so JS viewport
/// queries, hit-testing, and the element picker all stay accurate.
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
    /// viewport`). ponytail: layout size + magnification only — no mobile
    /// user-agent or touch-event emulation; add a UA switch if a site
    /// serves a genuinely different mobile experience.
    var viewport: BrowserViewport = .fit
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

    /// Fill in workspace / project context when it becomes known (agent
    /// open path, or reusing a manual session). Never clears existing refs.
    func bindContext(workspace: Workspace?, projectSession: ProjectSession?) {
        if sourceWorkspace == nil { sourceWorkspace = workspace }
        if self.projectSession == nil { self.projectSession = projectSession }
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
            // CSS px → view coords: viewport presets scale content via
            // webView.magnification, and the snapshot rect is in view space.
            let m = webView.magnification
            capture(rect: CGRect(x: parts[0] * m, y: parts[1] * m,
                                 width: parts[2] * m, height: parts[3] * m),
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
        webView.evaluateJavaScript(
            "window.__agentidePicker && window.__agentidePicker.setActive(\(pickerActive))",
            completionHandler: nil)
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
      var HIGHLIGHT =
        'position:fixed;z-index:2147483646;pointer-events:none;box-sizing:border-box;' +
        'border:2px solid #007AFF;background:rgba(0,122,255,0.16);border-radius:4px;' +
        'box-shadow:0 0 0 1px rgba(0,122,255,0.35);display:none;';
      var MARQUEE =
        'position:fixed;z-index:2147483645;pointer-events:none;box-sizing:border-box;' +
        'border:1.5px dashed #007AFF;background:rgba(0,122,255,0.08);display:none;';
      var CHIP =
        'position:fixed;z-index:2147483647;display:none;box-sizing:border-box;' +
        'min-width:240px;max-width:380px;padding:6px 8px;border-radius:10px;' +
        'background:rgba(28,28,30,0.96);border:1px solid rgba(255,255,255,0.12);' +
        'box-shadow:0 8px 28px rgba(0,0,0,0.45);font:12px -apple-system,system-ui,sans-serif;' +
        'color:#f5f5f7;';

      var boxPool = [];
      var marquee = document.createElement('div');
      marquee.setAttribute('data-agentide-ui', '1');
      marquee.style.cssText = MARQUEE;

      var chip = document.createElement('div');
      chip.setAttribute('data-agentide-ui', '1');
      chip.style.cssText = CHIP;
      chip.innerHTML =
        '<div data-agentide-hint style="font-size:10px;opacity:0.55;margin:0 0 4px 2px;letter-spacing:0.02em;">' +
        'Annotate · Enter sends & exits · Esc clears · ⇧/⌘-click or ⇧-drag groups</div>' +
        '<input type="text" data-agentide-ui="1" placeholder="What should change?" ' +
        'style="width:100%;box-sizing:border-box;border:none;outline:none;' +
        'background:rgba(255,255,255,0.08);color:#f5f5f7;border-radius:6px;' +
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

      function isUI(el) {
        return !!(el && el.closest && el.closest('[data-agentide-ui]'));
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
        if (!marquee.isConnected) { document.body.appendChild(marquee); }
        if (!chip.isConnected) { document.body.appendChild(chip); }
        boxPool.forEach(function (b) {
          if (!b.isConnected) { document.body.appendChild(b); }
        });
      }

      function acquireBox() {
        for (var i = 0; i < boxPool.length; i++) {
          if (boxPool[i].style.display === 'none') { return boxPool[i]; }
        }
        var b = document.createElement('div');
        b.setAttribute('data-agentide-ui', '1');
        b.style.cssText = HIGHLIGHT;
        boxPool.push(b);
        if (document.body) { document.body.appendChild(b); }
        return b;
      }

      function hideAllBoxes() {
        boxPool.forEach(function (b) { b.style.display = 'none'; });
      }

      function clearElementOutlines() {
        try {
          document.querySelectorAll('.' + HL_CLASS).forEach(function (el) {
            el.classList.remove(HL_CLASS);
          });
        } catch (e) {}
      }

      function placeBox(box, el) {
        if (!el || !el.getBoundingClientRect) { box.style.display = 'none'; return; }
        var r = el.getBoundingClientRect();
        if (r.width < 1 || r.height < 1) { box.style.display = 'none'; return; }
        box.style.display = 'block';
        box.style.left = Math.round(r.left) + 'px';
        box.style.top = Math.round(r.top) + 'px';
        box.style.width = Math.max(0, Math.round(r.width)) + 'px';
        box.style.height = Math.max(0, Math.round(r.height)) + 'px';
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

      function hideMarquee() { marquee.style.display = 'none'; }

      function updateMarquee(x1, y1, x2, y2) {
        ensureMounted();
        var left = Math.min(x1, x2);
        var top = Math.min(y1, y2);
        var w = Math.abs(x2 - x1);
        var h = Math.abs(y2 - y1);
        marquee.style.display = 'block';
        marquee.style.left = left + 'px';
        marquee.style.top = top + 'px';
        marquee.style.width = w + 'px';
        marquee.style.height = h + 'px';
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
        if (isUI(el)) { return false; }
        var tag = el.tagName;
        if (/^(SCRIPT|STYLE|META|LINK|BR|HR|NOSCRIPT|SVG|PATH)$/i.test(tag)) { return false; }
        var r = el.getBoundingClientRect();
        if (r.width < 10 || r.height < 10) { return false; }
        // Skip near-viewport wrappers that swallow multi-select.
        if (r.width > window.innerWidth * 0.92 && r.height > window.innerHeight * 0.55) {
          return false;
        }
        var role = (el.getAttribute('role') || '').toLowerCase();
        var cls = (typeof el.className === 'string' ? el.className : '').toLowerCase();
        var interactive = /^(A|BUTTON|INPUT|SELECT|TEXTAREA|LABEL|SUMMARY|DETAILS|IMG|VIDEO|CANVAS)$/i.test(tag)
          || typeof el.onclick === 'function'
          || el.hasAttribute('tabindex')
          || el.hasAttribute('contenteditable')
          || /^(button|link|checkbox|radio|tab|menuitem|option|switch|textbox|listitem|article|card|group)$/.test(role);
        if (interactive) { return true; }
        if (/^(LI|ARTICLE|SECTION|ASIDE|FIGURE|FIELDSET|TR|TD|TH|HEADER|FOOTER|NAV|MAIN|FORM|UL|OL|DL)$/i.test(tag)) {
          return true;
        }
        // Common component class hints (cards, tiles, rows, items).
        if (/\b(card|tile|item|row|cell|panel|widget|product|post|entry|box|col|column|grid-item)\b/.test(cls)) {
          return true;
        }
        if (r.width >= 36 && r.height >= 20 && r.width * r.height >= 900) { return true; }
        return false;
      }

      /// Score how "component-like" an element is for multi-select grouping.
      /// Higher = better peer to keep when marquee-selecting cards/items.
      function componentScore(el) {
        var r = el.getBoundingClientRect();
        var area = r.width * r.height;
        var vp = window.innerWidth * window.innerHeight;
        var score = 0;
        var tag = el.tagName;
        var role = (el.getAttribute('role') || '').toLowerCase();
        var cls = (typeof el.className === 'string' ? el.className : '').toLowerCase();
        if (/^(LI|ARTICLE|SECTION|ASIDE|FIGURE|A|BUTTON|IMG|TR)$/i.test(tag)) { score += 4; }
        if (/listitem|article|card|button|link/.test(role)) { score += 4; }
        if (/\b(card|tile|item|row|product|post|entry|grid-item)\b/.test(cls)) { score += 5; }
        // Prefer mid-size peers (cards), not tiny icons or giant sections.
        var frac = area / Math.max(1, vp);
        if (frac > 0.002 && frac < 0.25) { score += 3; }
        else if (frac >= 0.25) { score -= 2; }
        // Similar aspect ratio to a card/row helps grouping.
        var ar = r.width / Math.max(1, r.height);
        if (ar > 0.4 && ar < 6) { score += 1; }
        // Prefer direct children of flex/grid parents (common card lists).
        var p = el.parentElement;
        if (p) {
          try {
            var cs = window.getComputedStyle(p);
            if (cs.display === 'flex' || cs.display === 'grid'
                || cs.display === 'inline-flex' || cs.display === 'inline-grid') {
              score += 3;
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
        var hits = [];
        var all = document.body ? document.body.querySelectorAll('*') : [];
        var marqueeArea = Math.max(1, m.width * m.height);
        // Center-in-marquee is the most reliable multi-card signal.
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
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
          var inside = overlap / area;
          var covers = overlap / marqueeArea;
          // Keep if center is in marquee, mostly inside, or marquee covers a useful chunk.
          if (!centerIn && inside < 0.3 && covers < 0.05) { continue; }
          hits.push({
            el: el,
            score: (centerIn ? 3 : 0) + inside * 2 + covers + componentScore(el) * 0.15,
            area: area
          });
        }
        hits.sort(function (a, b) { return b.score - a.score || a.area - b.area; });
        // Cap raw hits before grouping to keep work bounded.
        var els = hits.slice(0, 80).map(function (h) { return h.el; });
        els = groupComponents(els);
        if (!els.length) {
          var mx = (m.left + m.right) / 2;
          var my = (m.top + m.bottom) / 2;
          var hit = pickDeepestAt(mx, my);
          if (hit) { els = [hit]; }
        }
        return els.slice(0, MAX_SELECT);
      }

      function pickDeepestAt(x, y) {
        var hit = document.elementFromPoint(x, y);
        if (!hit || isUI(hit) || !(hit instanceof Element)) { return null; }
        // Walk up collecting candidates; prefer best component score near the leaf.
        var node = hit;
        var candidates = [];
        while (node && node !== document.body) {
          if (isComponentCandidate(node)) { candidates.push(node); }
          node = node.parentElement;
        }
        if (!candidates.length) {
          return hit instanceof Element ? hit : null;
        }
        // Prefer the tightest good component (first few ancestors), scored.
        var best = candidates[0];
        var bestS = componentScore(best);
        for (var i = 1; i < Math.min(candidates.length, 5); i++) {
          var s = componentScore(candidates[i]);
          // Prefer deeper (smaller) unless outer scores clearly better (card vs icon).
          if (s > bestS + 2) {
            best = candidates[i];
            bestS = s;
          }
        }
        return best;
      }

      function hideChip() {
        chip.style.display = 'none';
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
        state.selected.forEach(function (el) {
          if (!el.getBoundingClientRect) { return; }
          var r = el.getBoundingClientRect();
          left = Math.min(left, r.left);
          top = Math.min(top, r.top);
          right = Math.max(right, r.right);
          bottom = Math.max(bottom, r.bottom);
        });
        if (!isFinite(left)) { left = 16; top = 16; right = 16; bottom = 16; }
        var chipW = 300;
        var cLeft = Math.min(Math.max(8, left), window.innerWidth - chipW - 8);
        var cTop = bottom + 8;
        if (cTop + 64 > window.innerHeight) {
          cTop = Math.max(8, top - 64);
        }
        chip.style.display = 'block';
        chip.style.left = cLeft + 'px';
        chip.style.top = cTop + 'px';
        chip.style.width = chipW + 'px';
        setTimeout(function () { try { input.focus(); input.select(); } catch (e) {} }, 0);
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
        if (isUI(e.target)) { return; }
        var el = pickDeepestAt(e.clientX, e.clientY);
        state.hover = el;
        if (!state.selected.length) { paintSelection(); }
      }

      function onDown(e) {
        if (!state.active || e.button !== 0) { return; }
        if (isUI(e.target)) { return; }
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
        if (!state.active || !state.dragging) { return; }
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
        if (isUI(e.target)) { return; }
        e.preventDefault();
        e.stopPropagation();
      }

      function onKey(e) {
        if (!state.active) { return; }
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
        if (e.key === 'Enter' && state.annotating && document.activeElement === input) {
          e.preventDefault();
          e.stopPropagation();
          submitAnnotation();
        }
      }

      input.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') {
          e.preventDefault();
          e.stopPropagation();
          submitAnnotation();
        } else if (e.key === 'Escape') {
          e.preventDefault();
          e.stopPropagation();
          clearSelection();
        }
      });

      window.__agentidePicker = {
        setActive: function (on) {
          state.active = !!on;
          document.documentElement.style.cursor = on ? 'crosshair' : '';
          if (!on) { clearSelection(); }
          else { ensureMounted(); state.suppressHover = false; paintSelection(); }
        },
        clear: function () { clearSelection(); }
      };

      document.addEventListener('mousemove', onMove, true);
      document.addEventListener('mousedown', onDown, true);
      document.addEventListener('mouseup', onUp, true);
      document.addEventListener('click', onClick, true);
      document.addEventListener('keydown', onKey, true);
      window.addEventListener('scroll', function () {
        if (state.active && (state.selected.length || state.hover)) { paintSelection(); }
      }, true);
      window.addEventListener('resize', function () {
        if (state.active && (state.selected.length || state.hover)) { paintSelection(); }
      }, true);
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
