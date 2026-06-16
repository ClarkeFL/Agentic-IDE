import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Full-bleed "Ask anything" overlay. Slides over the main 4-pane layout when
/// the user hits ⌘⇧A or picks Ask → Ask from the menu bar. The chat is rendered
/// as native SwiftUI bubbles — right-aligned for the user, full-width markdown
/// for the assistant — even though the answer is produced by a CLI subprocess
/// (`claude -p` / `codex exec`). The composer carries the provider / model /
/// effort pickers so the user can steer each question without leaving the box.
struct AskOverlay: View {
    @Environment(AskSession.self) private var session
    @Binding var isPresented: Bool

    @State private var input: String = ""
    @State private var inputHeight: CGFloat = 22
    @State private var attachments: [PendingAttachment] = []

    private let columnWidth: CGFloat = 760

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.Space.md) {
            Button { close() } label: {
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
                    headerButton("Stop", icon: "stop.fill") { session.cancel() }
                } else if !session.messages.isEmpty {
                    headerButton("Clear", icon: "trash") { session.clear() }
                }
            }
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.leading, DS.Layout.trafficLightInset)
        .frame(height: DS.Control.header + DS.Space.lg)
    }

    private func headerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(DS.Font.control)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.md)
                .frame(height: DS.Control.large)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xxl) {
                    if session.messages.isEmpty {
                        emptyState.padding(.top, DS.Space.xxxl * 2)
                    } else {
                        ForEach(session.messages) { message in
                            MessageBubble(
                                message: message,
                                isStreaming: session.streamingMessageId == message.id
                            )
                            .id(message.id)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchorId)
                }
                .padding(.horizontal, DS.Space.xxxl)
                .padding(.vertical, DS.Space.xl)
                .frame(maxWidth: columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: session.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: session.messages.last?.text) { _, _ in scrollToBottom(proxy) }
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
            Text("Quick questions, no project required. Return to send, ⇧Return for a new line. Press ⌘⇧A any time to toggle.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Composer

    private var composer: some View {
        @Bindable var session = session
        return VStack(spacing: DS.Space.sm) {
            if !attachments.isEmpty {
                attachmentStrip
            }

            ChatInputTextView(
                text: $input,
                height: $inputHeight,
                minHeight: 22,
                maxHeight: 180,
                isEnabled: !session.isStreaming,
                onSend: submit,
                onPasteImage: { addAttachment(image: $0) }
            )
            .frame(height: inputHeight)
            .overlay(alignment: .topLeading) {
                if input.isEmpty {
                    Text("Ask anything…")
                        .font(.system(size: DS.FontSize.body + 1))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: DS.Space.sm) {
                attachButton
                providerPicker(session: session)
                modelPicker(session: session)
                effortPicker(session: session)
                Spacer()
                sendButton
            }
        }
        .padding(DS.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg + 4, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg + 4, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .padding(.horizontal, DS.Space.xxxl)
        .padding(.bottom, DS.Space.xl)
        .padding(.top, DS.Space.sm)
        .frame(maxWidth: columnWidth + DS.Space.xxxl * 2)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Pickers

    private func providerPicker(session: AskSession) -> some View {
        Menu {
            Picker(selection: Binding(get: { session.provider }, set: { session.provider = $0 })) {
                ForEach(AskProvider.allCases) { provider in
                    Label(provider.displayName, systemImage: provider.symbol).tag(provider)
                }
            } label: { Text("AI") }
            .pickerStyle(.inline)
        } label: {
            chip(icon: session.provider.symbol, text: session.provider.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func modelPicker(session: AskSession) -> some View {
        Menu {
            Picker(selection: Binding(get: { session.model }, set: { session.model = $0 })) {
                ForEach(session.provider.models) { model in
                    Text(model.label).tag(model)
                }
            } label: { Text("Model") }
            .pickerStyle(.inline)
        } label: {
            chip(icon: nil, text: session.model.label)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func effortPicker(session: AskSession) -> some View {
        Menu {
            Picker(selection: Binding(get: { session.effort }, set: { session.effort = $0 })) {
                ForEach(session.provider.effortLevels) { level in
                    Text(level.label).tag(level)
                }
            } label: { Text("Effort") }
            .pickerStyle(.inline)
        } label: {
            chip(icon: "gauge.with.dots.needle.50percent", text: "Effort: \(session.effort.label)")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func chip(icon: String?, text: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            if let icon {
                Image(systemName: icon).font(.system(size: DS.Icon.small))
            }
            Text(text).font(DS.Font.control)
            Image(systemName: "chevron.down")
                .font(.system(size: DS.Icon.micro, weight: .semibold))
                .opacity(0.5)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Space.sm)
        .frame(height: DS.Control.large)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .contentShape(Rectangle())
    }

    // MARK: Attachments

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.sm) {
                ForEach(attachments) { attachment in
                    Image(nsImage: attachment.image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                        .overlay(alignment: .topTrailing) {
                            Button { removeAttachment(attachment) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: DS.FontSize.body))
                                    .foregroundStyle(.white, .black.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                            .help("Remove")
                            .offset(x: 6, y: -6)
                        }
                        .padding(.top, 6)
                        .padding(.trailing, 6)
                }
            }
        }
        .frame(height: 60)
    }

    private var attachButton: some View {
        Button { pickImages() } label: {
            Image(systemName: "paperclip")
                .font(.system(size: DS.FontSize.body + 1))
                .foregroundStyle(.secondary)
                .frame(width: DS.Control.large, height: DS.Control.large)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Attach image")
    }

    private func addAttachment(image: NSImage) {
        guard let url = Self.writePNG(image) else { return }
        attachments.append(PendingAttachment(url: url, image: image))
    }

    private func addAttachment(url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        attachments.append(PendingAttachment(url: url, image: image))
    }

    private func removeAttachment(_ attachment: PendingAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls { addAttachment(url: url) }
        }
    }

    /// Write a pasted image to a temp PNG so we have a stable file path to hand
    /// the CLI. Files live under a per-app temp dir; the OS reaps them.
    private static func writePNG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgenticIDE-ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).png")
        do { try png.write(to: url); return url } catch { return nil }
    }

    private var sendButton: some View {
        Button {
            if session.isStreaming { session.cancel() } else { submit() }
        } label: {
            Image(systemName: session.isStreaming ? "stop.fill" : "arrow.up")
                .font(.system(size: DS.FontSize.body, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(buttonFill))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!canSend && !session.isStreaming)
        .help(session.isStreaming ? "Stop" : "Send (Return)")
    }

    private var buttonFill: Color {
        if session.isStreaming { return .accentColor }
        return canSend ? .accentColor : Color.gray.opacity(0.4)
    }

    private var canSend: Bool {
        let hasText = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !attachments.isEmpty) && !session.isStreaming
    }

    private var headerTitle: String {
        "Ask \(session.provider.displayName)"
    }

    // MARK: - Actions

    private func submit() {
        guard canSend else { return }
        session.send(prompt: input, attachments: attachments.map(\.url))
        input = ""
        attachments = []
    }

    private func close() {
        // Don't drop in-flight streams when the user just wants to peek back at
        // the IDE — they can re-open with ⌘⇧A and the answer keeps filling in.
        isPresented = false
    }
}

// MARK: - Bubble

private struct MessageBubble: View {
    let message: AskSession.Message
    let isStreaming: Bool

    @State private var isHovering = false

    var body: some View {
        switch message.role {
        case .user:    userBubble
        case .assistant: assistantTurn
        case .error:   errorTurn
        }
    }

    // Right-aligned tinted bubble, capped well short of the column edge.
    // Any attached images sit above the text bubble.
    private var userBubble: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: DS.Space.sm) {
                if !message.attachments.isEmpty {
                    HStack(spacing: DS.Space.sm) {
                        ForEach(message.attachments, id: \.self) { url in
                            thumbnail(url)
                        }
                    }
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: DS.FontSize.body + 1))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, DS.Space.lg)
                        .padding(.vertical, DS.Space.md)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.lg + 4, style: .continuous)
                                .fill(Color.accentColor.opacity(0.16))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.lg + 4, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
                        )
                }
            }
        }
    }

    private func thumbnail(_ url: URL) -> some View {
        Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.15)
            }
        }
        .frame(width: 132, height: 132)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg + 2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg + 2, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var assistantTurn: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                avatar(icon: message.providerSymbol ?? "sparkles", fg: .purple, bg: Color.purple.opacity(0.18))
                Text(message.senderLabel ?? "Assistant")
                    .font(DS.Font.control)
                    .foregroundStyle(.secondary)
                Spacer()
                if !message.text.isEmpty {
                    CopyButton(text: message.text, label: nil)
                        .opacity(isHovering ? 1 : 0)
                }
            }

            Group {
                if message.text.isEmpty && isStreaming {
                    TypingIndicator().padding(.vertical, DS.Space.xs)
                } else {
                    AskMarkdownView(text: message.text)
                }
            }
            .padding(.leading, 28 + DS.Space.sm)   // align under the label, past the avatar
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    private var errorTurn: some View {
        HStack(alignment: .top, spacing: DS.Space.sm) {
            avatar(icon: "exclamationmark.triangle.fill", fg: .red, bg: Color.red.opacity(0.18))
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Error").font(DS.Font.control).foregroundStyle(.secondary)
                Text(message.text)
                    .font(.system(size: DS.FontSize.body + 1))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func avatar(icon: String, fg: Color, bg: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: DS.FontSize.body, weight: .medium))
            .foregroundStyle(fg)
            .frame(width: 28, height: 28)
            .background(Circle().fill(bg))
    }
}

// MARK: - Typing indicator

/// Three pulsing dots shown in the assistant bubble before the first token
/// lands. Cheap, and reads as "thinking…" the way chat UIs do.
/// An image staged in the composer but not yet sent. Holds the on-disk URL we
/// hand the CLI plus the decoded `NSImage` for the thumbnail.
private struct PendingAttachment: Identifiable {
    let id = UUID()
    let url: URL
    let image: NSImage
}

private struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 6, height: 6)
                    .scaleEffect(animating ? 1 : 0.5)
                    .opacity(animating ? 1 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.5).repeatForever().delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
