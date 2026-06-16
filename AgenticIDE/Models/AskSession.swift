import Foundation
import Observation

/// In-memory, project-agnostic chat thread for the Ask overlay (⌘⇧A).
/// Ephemeral by design — fresh on every app launch — so there's no storage
/// layer and no migrations to think about. Backs onto `AskService` which
/// spawns `claude -p` (or whatever the user has configured) as a subprocess
/// and streams stdout into the assistant placeholder bubble.
@MainActor
@Observable
final class AskSession {
    /// Single chat-bubble entry. `text` is mutated in place during streaming
    /// so the same `id` keeps its scroll position in `LazyVStack`.
    struct Message: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant, error }
        let id: UUID
        let role: Role
        var text: String
        /// Heading for an assistant turn — the model that actually answered,
        /// e.g. "Claude Opus" / "Codex GPT-5.5". `nil` for user / error rows.
        var senderLabel: String?
        /// SF Symbol for the assistant avatar (provider-specific).
        var providerSymbol: String?
        /// Local image files attached to a user message (paste / attach).
        var attachments: [URL]

        init(id: UUID = UUID(), role: Role, text: String = "",
             senderLabel: String? = nil, providerSymbol: String? = nil,
             attachments: [URL] = []) {
            self.id = id
            self.role = role
            self.text = text
            self.senderLabel = senderLabel
            self.providerSymbol = providerSymbol
            self.attachments = attachments
        }
    }

    private(set) var messages: [Message] = []
    private(set) var isStreaming: Bool = false

    /// Identifier of the currently-streaming assistant bubble, used by the
    /// view to show a typing indicator only on the bubble that's actually
    /// being filled in (the others are finished assistant turns).
    private(set) var streamingMessageId: UUID?

    // MARK: - Provider / model / effort selection

    /// Which CLI the next message goes to. Restored from `AppSettings` on
    /// launch and persisted on change so the picker remembers your choice.
    /// Switching providers reloads that provider's last model + clamps effort.
    var provider: AskProvider {
        didSet {
            guard provider != oldValue else { return }
            AppSettings.askProvider = provider
            model = AppSettings.askModel(for: provider)
            effort = AppSettings.askEffort(for: provider)
        }
    }

    var model: AskModel {
        didSet { AppSettings.setAskModel(model, for: provider) }
    }

    var effort: AskEffort {
        didSet { AppSettings.setAskEffort(effort, for: provider) }
    }

    init() {
        let provider = AppSettings.askProvider
        self.provider = provider
        self.model = AppSettings.askModel(for: provider)
        self.effort = AppSettings.askEffort(for: provider)
    }

    @ObservationIgnored
    private var currentTask: Task<Void, Never>?

    /// Heading for the assistant bubble: provider name plus the model alias
    /// when a specific one is picked ("Claude Opus", "Codex GPT-5.5"). On the
    /// Auto/Default model it's just the provider ("Claude").
    private func currentSenderLabel() -> String {
        model.flag == nil ? provider.displayName : "\(provider.displayName) \(model.label)"
    }

    func send(prompt: String, attachments: [URL] = []) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !isStreaming else { return }

        messages.append(Message(role: .user, text: trimmed, attachments: attachments))
        let placeholderId = UUID()
        messages.append(Message(
            id: placeholderId, role: .assistant, text: "",
            senderLabel: currentSenderLabel(), providerSymbol: provider.symbol
        ))
        isStreaming = true
        streamingMessageId = placeholderId

        // Empty text + image(s) → a sensible default so Codex (which wants a
        // prompt) and Claude both have something to act on.
        let basePrompt = trimmed.isEmpty ? "Describe the attached image(s)." : trimmed
        let invocation = provider.invocation(
            prompt: basePrompt,
            model: model,
            effort: effort,
            dangerous: AppSettings.askDangerous(for: provider),
            imagePaths: attachments.map(\.path)
        )

        currentTask = Task { @MainActor [weak self] in
            do {
                for try await chunk in AskService.stream(prompt: invocation.prompt, command: invocation.command) {
                    if Task.isCancelled { break }
                    guard let self else { return }
                    let cleaned = Self.stripAnsi(chunk)
                    if let idx = self.messages.firstIndex(where: { $0.id == placeholderId }) {
                        self.messages[idx].text.append(cleaned)
                    }
                }
                self?.finishStreaming(removingEmptyPlaceholder: placeholderId)
            } catch is CancellationError {
                self?.finishStreaming(removingEmptyPlaceholder: placeholderId)
            } catch {
                guard let self else { return }
                if let idx = self.messages.firstIndex(where: { $0.id == placeholderId }),
                   self.messages[idx].text.isEmpty {
                    self.messages.remove(at: idx)
                }
                self.messages.append(Message(role: .error, text: error.localizedDescription))
                self.finishStreaming(removingEmptyPlaceholder: nil)
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        if let id = streamingMessageId,
           let idx = messages.firstIndex(where: { $0.id == id }),
           messages[idx].text.isEmpty {
            messages.remove(at: idx)
        }
        isStreaming = false
        streamingMessageId = nil
    }

    func clear() {
        cancel()
        messages.removeAll()
    }

    private func finishStreaming(removingEmptyPlaceholder placeholderId: UUID?) {
        if let placeholderId,
           let idx = messages.firstIndex(where: { $0.id == placeholderId }),
           messages[idx].text.isEmpty {
            messages.remove(at: idx)
        }
        isStreaming = false
        streamingMessageId = nil
        currentTask = nil
    }

    /// Strip the most common ANSI CSI / OSC escape sequences. Claude with
    /// `NO_COLOR=1` is usually clean, but tools upstream of it (npm wrappers,
    /// shell hooks) occasionally still emit `\x1b[...m` colour runs or `\x1b]…\a`
    /// title sets that we don't want rendered literally as `[?2004h…`.
    private static func stripAnsi(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{1B}" {
                guard let next = iterator.next() else { break }
                if next == "[" {
                    while let ch = iterator.next() {
                        // CSI runs until a final byte in 0x40..0x7E.
                        if (0x40...0x7E).contains(ch.value) { break }
                    }
                } else if next == "]" {
                    while let ch = iterator.next() {
                        // OSC runs until BEL or ESC \.
                        if ch == "\u{07}" { break }
                        if ch == "\u{1B}" { _ = iterator.next(); break }
                    }
                }
                // Other ESC-prefixed sequences: drop the ESC + one byte and continue.
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
