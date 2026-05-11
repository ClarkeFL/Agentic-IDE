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

        init(id: UUID = UUID(), role: Role, text: String = "") {
            self.id = id
            self.role = role
            self.text = text
        }
    }

    private(set) var messages: [Message] = []
    private(set) var isStreaming: Bool = false

    /// Identifier of the currently-streaming assistant bubble, used by the
    /// view to show a typing indicator only on the bubble that's actually
    /// being filled in (the others are finished assistant turns).
    private(set) var streamingMessageId: UUID?

    @ObservationIgnored
    private var currentTask: Task<Void, Never>?

    func send(prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        messages.append(Message(role: .user, text: trimmed))
        let placeholderId = UUID()
        messages.append(Message(id: placeholderId, role: .assistant, text: ""))
        isStreaming = true
        streamingMessageId = placeholderId

        currentTask = Task { @MainActor [weak self] in
            do {
                for try await chunk in AskService.stream(prompt: trimmed) {
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
