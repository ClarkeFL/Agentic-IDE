import Foundation
import OSLog

/// Spawns the user's preferred "ask" CLI in print mode and streams its stdout
/// back as text chunks. Used by the Ask overlay (⌘⇧A) so the user can throw
/// quick questions at `claude -p` / `codex exec` / whatever without leaving
/// AgenticIDE and without opening a terminal pane.
///
/// Why a subprocess and not the Anthropic / OpenAI API directly: the upstream
/// CLIs already handle auth, model selection, and any sandbox flags the user
/// has configured. We're a thin presentation layer.
enum AskService {
    private static let log = Logger(subsystem: "com.fabio.AgenticIDE", category: "Ask")

    enum AskError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let msg): return msg
            }
        }
    }

    /// Stream the answer to `prompt`. The base invocation comes from
    /// `AppSettings.askCommand` (default `claude -p`); the prompt is appended
    /// as a single-quoted positional argument with embedded apostrophes
    /// escaped. Cancellation (`continuation.onTermination`) terminates the
    /// underlying process so a half-finished answer doesn't keep streaming
    /// after the user closes the overlay.
    static func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let baseCommand = AppSettings.askCommand
            let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
            // `export NO_COLOR=1` AFTER the profile runs so an interactive rc
            // that re-enables color (claude / codex setups commonly do) can't
            // re-introduce ANSI sequences into our chat bubbles. `-ilc` is the
            // same pattern PtyService uses so PATH picks up nvm/asdf/brew CLIs.
            let fullCommand = "export NO_COLOR=1; \(baseCommand) '\(escapedPrompt)'"

            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-ilc", fullCommand]
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Run in $HOME so the CLI doesn't accidentally pick up an unrelated
            // project's CLAUDE.md / .codex-config from wherever the user last
            // had AgenticIDE chdir'd. The Ask overlay is intentionally project-
            // agnostic.
            if let home = ProcessInfo.processInfo.environment["HOME"] {
                process.currentDirectoryURL = URL(fileURLWithPath: home)
            }

            var env = ProcessInfo.processInfo.environment
            env["NO_COLOR"] = "1"
            env.removeValue(forKey: "TERM_PROGRAM")
            process.environment = env

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    // EOF — pipe's write end closed. Tear down so we don't
                    // spin on empty reads after the child exits.
                    handle.readabilityHandler = nil
                    return
                }
                if let chunk = String(data: data, encoding: .utf8) {
                    continuation.yield(chunk)
                }
            }

            // We don't stream stderr to the UI live — most CLIs emit warnings
            // there (deprecation notices, telemetry pings) that would confuse
            // the chat thread. Collected for the failure path only.
            let stderrBuffer = StderrBuffer()
            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                stderrBuffer.append(data)
            }

            process.terminationHandler = { proc in
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil

                // Drain whatever the readability handler didn't catch between
                // its last fire and process exit. readToEnd returns the tail
                // bytes plus EOF, so it's safe to call even after EOF was
                // already observed.
                let stdoutTail = (try? stdoutHandle.readToEnd()) ?? Data()
                if let chunk = String(data: stdoutTail, encoding: .utf8), !chunk.isEmpty {
                    continuation.yield(chunk)
                }
                let stderrTail = (try? stderrHandle.readToEnd()) ?? Data()
                if !stderrTail.isEmpty { stderrBuffer.append(stderrTail) }

                if proc.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    let errText = stderrBuffer.string().trimmingCharacters(in: .whitespacesAndNewlines)
                    log.error("ask exit \(proc.terminationStatus): \(errText, privacy: .public)")
                    let msg = errText.isEmpty
                        ? "\(baseCommand) exited with status \(proc.terminationStatus)."
                        : errText
                    continuation.finish(throwing: AskError.failed(msg))
                }
            }

            continuation.onTermination = { _ in
                if process.isRunning {
                    process.terminate()
                }
            }

            do {
                try process.run()
            } catch {
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                continuation.finish(throwing: error)
            }
        }
    }

    /// Tiny thread-safe accumulator for the stderr stream. Plain `Data` is a
    /// value type and racy under multiple readability-handler callbacks; this
    /// keeps the append + final read on one serial lock.
    private final class StderrBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
        }
        func string() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
