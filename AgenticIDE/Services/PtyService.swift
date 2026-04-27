import Foundation

/// Resolves a `QuickLaunch` (or "+") into a SurfaceConfig that GhosttyTerminalView
/// can hand to ghostty_surface_new. Wraps user commands in `$SHELL -lc "<cmd>"`
/// so login init runs and PATH/env is correct (claude, codex, asdf, brew, etc.).
enum PtyService {
    static func defaultShell() -> String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Default-shell tab. No `command` set → ghostty spawns the user's login shell.
    static func defaultShellConfig(cwd: URL) -> SurfaceConfig {
        SurfaceConfig(command: nil, workingDirectory: cwd, env: [:])
    }

    /// Spawn a specific command via the user's login shell.
    /// We pass the whole "$SHELL -lc <cmd>" line as a single string in the
    /// surface config's `command` field; ghostty splits it argv-style.
    static func quickLaunchConfig(_ ql: QuickLaunch, cwd: URL) -> SurfaceConfig {
        let shell = defaultShell()
        let escaped = ql.command.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "\(shell) -lc '\(escaped)'"
        return SurfaceConfig(command: cmd, workingDirectory: cwd, env: [:])
    }
}
