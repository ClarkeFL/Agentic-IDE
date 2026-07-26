import AppKit
import Foundation
import OSLog

/// Plays the user-configured notification sound when an AI agent finishes a
/// turn — i.e. when a `TerminalTab`'s status flips from `.working` to
/// `.completed` / `.failed` (Stop hook, BEL, process exit, or the completion
/// timer; the trigger lives in `TerminalTab.status.didSet` so every signal
/// path is covered).
///
/// The sound is either one of the built-in macOS alert sounds (by name) or a
/// user-supplied audio file (MP3/M4A/WAV/AIFF — anything `NSSound` decodes)
/// imported via Settings → Notifications. Imported files are copied into
/// Application Support so the sound keeps working if the original moves.
final class CompletionSoundPlayer {
    static let shared = CompletionSoundPlayer()

    private static let log = Logger(subsystem: "com.fabio.AgenticIDE",
                                    category: "CompletionSoundPlayer")

    /// Built-in macOS alert sounds, available on every install without
    /// bundling assets. Resolved via `NSSound(named:)`.
    static let systemSoundNames = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    /// Sentinel stored in `AppSettings.Keys.completionSoundName` meaning
    /// "play the imported custom file" instead of a system sound.
    static let customSoundToken = "custom"

    /// Strong reference while playing — `NSSound` stops if deallocated
    /// mid-play.
    private var current: NSSound?

    private init() {}

    /// Called from `TerminalTab` on the working→finished transition.
    /// Respects the Settings toggle.
    func agentDidFinish() {
        guard UserDefaults.standard.bool(forKey: AppSettings.Keys.completionSoundEnabled) else { return }
        play()
    }

    /// Unconditional play — used by the Settings "Test" button so the user
    /// can preview the sound even before flipping the toggle on.
    func play() {
        guard let sound = resolveSound() else {
            Self.log.error("No playable completion sound for current settings")
            return
        }
        current?.stop()
        sound.volume = Self.configuredVolume()
        sound.play()
        current = sound
    }

    private static func configuredVolume() -> Float {
        let stored = UserDefaults.standard.object(forKey: AppSettings.Keys.completionSoundVolume) as? Double ?? 1
        return Float(min(max(stored, 0), 1))
    }

    private func resolveSound() -> NSSound? {
        let name = UserDefaults.standard.string(forKey: AppSettings.Keys.completionSoundName) ?? "Glass"
        if name == Self.customSoundToken {
            let path = UserDefaults.standard.string(forKey: AppSettings.Keys.customCompletionSoundPath) ?? ""
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
            return NSSound(contentsOf: URL(fileURLWithPath: path), byReference: true)
        }
        return NSSound(named: name)
    }

    // MARK: - Custom sound import

    /// Directory custom sounds are copied into:
    /// `~/Library/Application Support/AgenticIDE/sounds/`.
    static var soundsDirectoryURL: URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true)) ?? fm.temporaryDirectory
        return appSupport
            .appendingPathComponent("AgenticIDE", isDirectory: true)
            .appendingPathComponent("sounds", isDirectory: true)
    }

    /// Copies a user-picked audio file into Application Support and returns
    /// the stored path. Throws if the file can't be decoded as audio so the
    /// Settings UI can surface "not a playable file" instead of silently
    /// accepting something that will never play.
    static func importCustomSound(from source: URL) throws -> String {
        guard NSSound(contentsOf: source, byReference: true) != nil else {
            throw NSError(
                domain: "CompletionSoundPlayer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                            "\(source.lastPathComponent) isn't a playable audio file."]
            )
        }
        let fm = FileManager.default
        let dir = soundsDirectoryURL
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: source, to: dest)
        log.info("Imported custom completion sound: \(dest.path, privacy: .public)")
        return dest.path
    }
}
