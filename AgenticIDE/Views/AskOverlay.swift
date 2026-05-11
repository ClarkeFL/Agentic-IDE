import SwiftUI

/// Full-bleed "Ask anything" overlay. Slides over the main 4-pane layout when
/// the user hits ⌘⇧A or picks Ask → Ask from the menu bar. The chat itself is
/// rendered as native SwiftUI bubbles even though the answer is produced by a
/// CLI subprocess (`claude -p` by default) — the user explicitly didn't want
/// this to look like another terminal pane.
struct AskOverlay: View {
    @Environment(AskSession.self) private var session
    @Binding var isPresented: Bool

    @State private var input: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { inputFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.Space.md) {
            Button {
                close()
            } label: {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: DS.FontSize.body, weight: .semibold))
                    Text("Back")
                        .font(DS.Font.control)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.md)
                .frame(height: DS.Control.large)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            Text(headerTitle)
                .font(.system(size: DS.FontSize.body, weight: .semibold))

            Spacer()

            HStack(spacing: DS.Space.sm) {
                if session.isStreaming {
                    Button {
                        session.cancel()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(DS.Font.control)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, DS.Space.md)
                            .frame(height: DS.Control.large)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if !session.messages.isEmpty {
                    Button {
                        session.clear()
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .font(DS.Font.control)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, DS.Space.md)
                            .frame(height: DS.Control.large)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, DS.Space.xl)
        // Leave room for the traffic-light buttons under `.hiddenTitleBar`.
        .padding(.leading, DS.Layout.trafficLightInset)
        .frame(height: DS.Control.header + DS.Space.lg)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    if session.messages.isEmpty {
                        emptyState
                            .padding(.top, DS.Space.xxxl * 2)
                    } else {
                        ForEach(session.messages) { message in
                            MessageBubble(
                                message: message,
                                isStreaming: session.streamingMessageId == message.id
                            )
                            .id(message.id)
                        }
                    }

                    // Bottom sentinel so the latest bubble can scroll fully
                    // into view above the composer (otherwise the last line
                    // sits glued to the divider).
                    Color.clear.frame(height: 1).id(Self.bottomAnchorId)
                }
                .padding(.horizontal, DS.Space.xxxl)
                .padding(.vertical, DS.Space.xl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            // Auto-scroll on each new message AND on streaming text growth so
            // the reader's eye stays at the live edge. ScrollViewReader needs
            // a stable id, so we anchor to a 1pt sentinel at the bottom.
            .onChange(of: session.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: session.messages.last?.text) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private static let bottomAnchorId = "ask.transcript.bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(Self.bottomAnchorId, anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.lg) {
            Image(systemName: "sparkles")
                .font(.system(size: DS.Icon.display, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Ask anything")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Quick questions, no project required. Press ⌘⇧A any time to toggle.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: DS.Space.md) {
            TextField("Ask anything…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...8)
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.md)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.lg)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.lg)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .focused($inputFocused)

            sendButton
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var sendButton: some View {
        Button {
            if session.isStreaming {
                session.cancel()
            } else {
                submit()
            }
        } label: {
            Image(systemName: session.isStreaming ? "stop.fill" : "arrow.up")
                .font(.system(size: DS.FontSize.body, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(buttonFill)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!canSend && !session.isStreaming)
    }

    private var buttonFill: Color {
        if session.isStreaming { return .accentColor }
        return canSend ? .accentColor : Color.gray.opacity(0.4)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isStreaming
    }

    private var headerTitle: String {
        let first = AppSettings.askCommand
            .split(separator: " ")
            .first
            .map(String.init) ?? "Claude"
        let stem = (first as NSString).lastPathComponent
        return "Ask \(stem.capitalized)"
    }

    // MARK: - Actions

    private func submit() {
        let prompt = input
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !session.isStreaming else { return }
        session.send(prompt: prompt)
        input = ""
    }

    private func close() {
        // Don't drop in-flight streams when the user just wants to peek back
        // at the IDE — they can re-open with ⌘⇧A and the answer keeps filling
        // in. Only `Clear` actively terminates.
        isPresented = false
    }
}

// MARK: - Bubble

private struct MessageBubble: View {
    let message: AskSession.Message
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            avatar
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(roleLabel)
                    .font(DS.Font.control)
                    .foregroundStyle(.secondary)
                content
            }
            Spacer(minLength: 0)
        }
    }

    private var avatar: some View {
        Image(systemName: avatarIcon)
            .font(.system(size: DS.FontSize.body, weight: .medium))
            .foregroundStyle(avatarFG)
            .frame(width: 28, height: 28)
            .background(Circle().fill(avatarBG))
    }

    @ViewBuilder
    private var content: some View {
        switch message.role {
        case .error:
            Text(message.text)
                .font(.body)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .user, .assistant:
            if message.text.isEmpty && isStreaming {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, DS.Space.xs)
            } else {
                rendered
            }
        }
    }

    /// Inline markdown via `AttributedString(markdown:)`. The
    /// `inlineOnlyPreservingWhitespace` option keeps newlines from the model's
    /// output intact while still rendering `**bold**` / `*italic*` / code /
    /// links — full block-level markdown (lists, headings, tables, fenced code)
    /// would need a real markdown view; if we want that later, swap in a
    /// dedicated renderer here. Falls back to plain text if parsing fails.
    private var rendered: Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attr = try? AttributedString(markdown: message.text, options: options) {
            return Text(attr)
        }
        return Text(message.text)
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .error: return "Error"
        }
    }

    private var avatarIcon: String {
        switch message.role {
        case .user: return "person.fill"
        case .assistant: return "sparkles"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var avatarBG: Color {
        switch message.role {
        case .user: return Color.accentColor.opacity(0.18)
        case .assistant: return Color.purple.opacity(0.18)
        case .error: return Color.red.opacity(0.18)
        }
    }

    private var avatarFG: Color {
        switch message.role {
        case .user: return .accentColor
        case .assistant: return .purple
        case .error: return .red
        }
    }
}
