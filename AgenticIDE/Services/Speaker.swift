import AVFoundation
import Foundation
import Observation
import OSLog

/// Speaks text aloud. Behind a protocol so we can swap in a cloud-TTS provider
/// (ElevenLabs, OpenAI) later without touching call sites.
protocol Speaker: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ text: String)
    func stop()
}

/// Default implementation backed by macOS's built-in `AVSpeechSynthesizer`.
/// Uses the same TTS engine as the `say` command but exposes synchronous
/// stop/pause and per-utterance delegate callbacks (which we'll need for
/// read-along highlighting later).
@Observable
final class SystemSpeaker: NSObject, Speaker, AVSpeechSynthesizerDelegate {
    private let log = Logger(subsystem: "com.fabio.AgenticIDE", category: "Speaker")
    private let synthesizer = AVSpeechSynthesizer()

    /// Mirrors `synthesizer.isSpeaking` but is observable so SwiftUI can
    /// flip the speaker icon between play / stop without polling.
    private(set) var isSpeaking: Bool = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Cancel any ongoing utterance — pressing Speak twice in a row should
        // replace, not queue, so the user always hears the latest selection.
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: cleanForSpeech(trimmed))
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: AppSettings.Keys.speechVoiceIdentifier),
           let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
                ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        let storedRate = defaults.object(forKey: AppSettings.Keys.speechRate) as? Double
        utterance.rate = Float(storedRate ?? Double(AVSpeechUtteranceDefaultSpeechRate))
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// Strips terminal noise that doesn't read well: ANSI escape sequences,
    /// box-drawing borders, and runs of repeated punctuation like `────`.
    /// Conservative — anything we can't classify stays in.
    private func cleanForSpeech(_ s: String) -> String {
        var out = s
        // ANSI CSI / SGR sequences (ESC [ … letter)
        if let regex = try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;?]*[A-Za-z]") {
            out = regex.stringByReplacingMatches(in: out,
                                                  range: NSRange(out.startIndex..., in: out),
                                                  withTemplate: "")
        }
        // Box-drawing + block chars (U+2500..U+259F) — replace with space so
        // adjacent words stay separated.
        out = String(out.unicodeScalars.map { scalar -> Character in
            if (0x2500...0x259F).contains(scalar.value) { return " " }
            return Character(scalar)
        })
        // Collapse runs of whitespace.
        if let ws = try? NSRegularExpression(pattern: "[ \\t]{2,}") {
            out = ws.stringByReplacingMatches(in: out,
                                              range: NSRange(out.startIndex..., in: out),
                                              withTemplate: " ")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
    }
}
