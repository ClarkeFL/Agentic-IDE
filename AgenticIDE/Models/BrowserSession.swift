import AppKit
import Foundation
import Observation
import WebKit

/// All live agent browser panes, in creation order. One pane per owning
/// terminal (the agent that opened it via `agentide browser open`). Also owns
/// the browser-mode UI state: whether the full-window browser view is up and
/// which pane it shows. Ephemeral — nothing is persisted.
@Observable
final class BrowserManager {
    static let shared = BrowserManager()

    private(set) var sessions: [BrowserSession] = []
    var focusedId: UUID?
    /// True while the full-window browser mode (agent column + web view)
    /// replaces the normal three-pane layout.
    var isModeActive = false

    private init() {}

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
    func open(_ url: URL?, cell: WorkspaceCell) -> BrowserSession {
        let session: BrowserSession
        if let existing = self.session(for: cell) {
            session = existing
        } else {
            session = BrowserSession(cell: cell)
            sessions.append(session)
            if focusedId == nil { focusedId = session.id }
        }
        if let url { session.load(url) }
        return session
    }

    /// User-opened browser (workspace-header globe button): no owning cell
    /// yet — browser mode expands immediately and the left column offers the
    /// workspace's cells to attach one.
    func openManual(from workspace: Workspace) {
        let session = BrowserSession(cell: nil, workspace: workspace)
        sessions.append(session)
        focusedId = session.id
        isModeActive = true
    }

    func close(_ session: BrowserSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions.remove(at: idx)
        session.tearDown()
        if focusedId == session.id { focusedId = sessions.first?.id }
        if sessions.isEmpty { isModeActive = false }
    }

    /// A cell leaving the grid (workspace removed/resized) takes its browser
    /// with it. Closing just the cell's PROGRAM does not — the browser stays
    /// and the left column shows the launcher so a different agent can take
    /// over.
    func close(boundTo cell: WorkspaceCell) {
        guard let session = session(for: cell) else { return }
        close(session)
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
/// tied to the terminal that opened it (picker selections are typed into that
/// terminal's input).
@Observable
final class BrowserSession: NSObject, Identifiable, WKNavigationDelegate, WKScriptMessageHandler {
    let id = UUID()
    /// The grid cell this browser is bound to — the browser belongs to the
    /// CELL, not to a specific program: close the cell's agent and launch a
    /// different one, and the new agent inherits this pane. nil for a
    /// user-opened browser until a cell is attached.
    private(set) weak var ownerCell: WorkspaceCell?
    /// The workspace a user-opened browser came from — source of the cells
    /// offered by the attach picker. nil for agent-opened browsers (they
    /// already have an owner).
    private(set) weak var sourceWorkspace: Workspace?
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
    /// Element picker: while on, hovering highlights elements and clicking
    /// types the selection into the owning agent's input.
    var pickerActive = false {
        didSet { applyPicker() }
    }

    /// KVO on WKWebView.url / title / history — catches SPA pushState and
    /// in-page navigations that never fire WKNavigationDelegate.
    private var webViewObservations: [NSKeyValueObservation] = []

    init(cell: WorkspaceCell?, workspace: Workspace? = nil) {
        self.ownerCell = cell
        self.sourceWorkspace = workspace

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

    /// Give a user-opened browser its driving cell. From here on the cell's
    /// agent (current and future) owns this pane: its `agentide browser`
    /// verbs hit it and picker selections land in its input.
    func attach(to cell: WorkspaceCell) {
        ownerCell = cell
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
              let dict = message.body as? [String: Any],
              let selector = dict["selector"] as? String else { return }
        let text = (dict["text"] as? String) ?? ""
        let html = (dict["html"] as? String) ?? ""
        var line = "[browser pick] \(selector)"
        if !text.isEmpty { line += " | text: \"\(text)\"" }
        if !html.isEmpty { line += " | html: \(html)" }
        // ponytail: inserted WITHOUT submit so the user can append an
        // instruction ("make this blue") before pressing Enter themselves.
        // Must stay newline-free or the agent CLI submits early.
        let flat = line.replacingOccurrences(of: "\n", with: " ")
        ownerTab?.view.sendInput(flat + " ", submit: false)
    }

    // MARK: - Injected JS

    /// Hover-highlight + click-to-capture element picker. Injected on every
    /// page, dormant until `setActive(true)`.
    private static let pickerJS = #"""
    (function () {
      if (window.__agentidePicker) { return; }
      var box = document.createElement('div');
      box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;' +
        'border:2px solid #007AFF;background:rgba(0,122,255,0.12);border-radius:3px;display:none;';
      var state = { active: false, el: null };
      function cssPath(el) {
        if (el.id) { return '#' + CSS.escape(el.id); }
        var parts = [];
        var node = el;
        while (node && node.nodeType === 1 && node !== document.body && parts.length < 5) {
          if (node.id) { parts.unshift('#' + CSS.escape(node.id)); break; }
          var part = node.tagName.toLowerCase();
          var cls = (typeof node.className === 'string' ? node.className : '')
            .trim().split(/\s+/).filter(Boolean).slice(0, 2);
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
      function onMove(e) {
        if (!state.active) { return; }
        var el = e.target;
        if (el === box || !(el instanceof Element)) { return; }
        state.el = el;
        if (!box.isConnected && document.body) { document.body.appendChild(box); }
        var r = el.getBoundingClientRect();
        box.style.display = 'block';
        box.style.left = r.left + 'px';
        box.style.top = r.top + 'px';
        box.style.width = r.width + 'px';
        box.style.height = r.height + 'px';
      }
      function onClick(e) {
        if (!state.active || !state.el) { return; }
        e.preventDefault();
        e.stopPropagation();
        var el = state.el;
        var text = (el.innerText || el.value || '').trim().replace(/\s+/g, ' ').slice(0, 120);
        window.webkit.messageHandlers.agentidePicker.postMessage({
          selector: cssPath(el),
          text: text,
          html: el.outerHTML.replace(/\s+/g, ' ').slice(0, 400)
        });
      }
      window.__agentidePicker = {
        setActive: function (on) {
          state.active = on;
          document.documentElement.style.cursor = on ? 'crosshair' : '';
          if (!on) { box.style.display = 'none'; state.el = null; }
        }
      };
      document.addEventListener('mousemove', onMove, true);
      document.addEventListener('click', onClick, true);
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
