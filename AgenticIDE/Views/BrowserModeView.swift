import SwiftUI
import WebKit

/// Full-window browser mode: the owning agent's terminal on the left, its
/// browser pane on the right. Replaces the normal three-pane layout while
/// active (`BrowserManager.isModeActive`); the bottom pager switches between
/// cells that have browsers open.
struct BrowserModeView: View {
    @Bindable var manager: BrowserManager

    var body: some View {
        HStack(spacing: DS.Space.md) {
            agentColumn
                .frame(width: 380)
                .frame(maxHeight: .infinity)
                .paneCard(fill: Color(nsColor: .textBackgroundColor), insets: cardInsets)
            if let session = manager.focused {
                BrowserColumn(manager: manager, session: session)
                    .id(session.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .paneCard(fill: Color(nsColor: .controlBackgroundColor), insets: cardInsets)
            }
        }
        .padding(EdgeInsets(top: DS.Space.xs, leading: DS.Space.md,
                            bottom: DS.Space.md, trailing: DS.Space.md))
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The outer HStack padding supplies the window margins and the spacing
    /// supplies the seam, so the cards themselves carry none.
    private var cardInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    }

    // MARK: - Left: the agent driving the browser

    @ViewBuilder
    private var agentColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "terminal")
                    .font(.system(size: DS.Icon.small, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(manager.focused?.ownerTab?.title ?? "Agent")
                    .font(DS.Font.control)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, DS.Space.sm)
            .frame(height: DS.Control.header)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()

            if let tab = manager.focused?.ownerTab {
                GhosttyTerminal(view: tab.view, isActive: true, autoFocus: false)
            } else {
                VStack(spacing: DS.Space.md) {
                    Image(systemName: "terminal")
                        .font(.system(size: DS.Icon.large, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("The agent that owned this browser has closed.")
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
    @Bindable var manager: BrowserManager
    @Bindable var session: BrowserSession

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            WebView(webView: session.webView)
        }
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

            BrowserToolbarButton(systemName: "arrow.clockwise", help: "Reload") {
                session.webView.reload()
            }
            BrowserToolbarButton(systemName: "cursorarrow.rays",
                                 help: session.pickerActive
                                     ? "Picker on — click an element to send it to the agent"
                                     : "Pick an element to send to the agent",
                                 isActive: session.pickerActive) {
                session.pickerActive.toggle()
            }
            BrowserToolbarButton(systemName: "xmark", help: "Close this browser") {
                manager.close(ownerId: session.ownerId)
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
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: DS.Icon.small, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .frame(width: DS.Control.compact, height: DS.Control.compact)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(Color.accentColor.opacity(isActive ? 0.18 : 0.0))
                )
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(Color.primary.opacity(isHovered && !isActive ? 0.12 : 0.0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

private struct WebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
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
        .paneCard(fill: Color(nsColor: .controlBackgroundColor),
                  insets: EdgeInsets(top: DS.Space.xs, leading: 0,
                                     bottom: DS.Space.md, trailing: DS.Space.md))
        .onHover { hovering = $0 }
        .help("Show agent browser")
    }
}
