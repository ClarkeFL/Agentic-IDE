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

    func session(ownerId: UUID) -> BrowserSession? {
        sessions.first(where: { $0.ownerId == ownerId })
    }

    /// Open (or navigate) the browser pane owned by this terminal. Creating a
    /// pane makes the edge bar appear; it never auto-expands browser mode —
    /// the user chooses when to look.
    @discardableResult
    func open(_ url: URL, owner: TerminalTab) -> BrowserSession {
        let session: BrowserSession
        if let existing = self.session(ownerId: owner.id) {
            session = existing
        } else {
            session = BrowserSession(owner: owner)
            sessions.append(session)
            if focusedId == nil { focusedId = session.id }
        }
        session.load(url)
        return session
    }

    /// User-opened browser (workspace-header globe button): no owning agent
    /// yet — browser mode expands immediately and the left column offers the
    /// workspace's cells to attach one.
    func openManual(from workspace: Workspace) {
        let session = BrowserSession(owner: nil, workspace: workspace)
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

    func close(ownerId: UUID) {
        guard let session = session(ownerId: ownerId) else { return }
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
    /// The owning terminal's surface id (`TerminalTab.id`). nil for a
    /// user-opened browser until an agent is attached.
    private(set) var ownerId: UUID?
    private(set) weak var ownerTab: TerminalTab?
    /// The workspace a user-opened browser came from — source of the cells
    /// offered by the attach picker. nil for agent-opened browsers (they
    /// already have an owner).
    private(set) weak var sourceWorkspace: Workspace?
    let webView: WKWebView

    var urlString: String = ""
    var pageTitle: String = ""
    var isLoading = false
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

    init(owner: TerminalTab?, workspace: Workspace? = nil) {
        self.ownerId = owner?.id
        self.ownerTab = owner
        self.sourceWorkspace = workspace

        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.pickerJS,
                                              injectionTime: .atDocumentEnd,
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
    }

    /// Give a user-opened browser its driving agent. From here on that
    /// agent's `agentide browser` verbs hit this pane and picker selections
    /// land in its input.
    func attach(to tab: TerminalTab) {
        ownerId = tab.id
        ownerTab = tab
    }

    func load(_ url: URL) {
        urlString = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func tearDown() {
        pickerActive = false
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
    }

    // MARK: - Agent verbs

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

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        urlString = webView.url?.absoluteString ?? urlString
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        urlString = webView.url?.absoluteString ?? urlString
        pageTitle = webView.title ?? ""
        // The picker script re-injects on navigation but wakes up dormant.
        if pickerActive { applyPicker() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        isLoading = false
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
