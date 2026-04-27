import Foundation

/// Resolves a `QuickLaunch` (or "+") into a SurfaceConfig that GhosttyTerminalView
/// can hand to ghostty_surface_new. Wraps user commands in `$SHELL -lc "<cmd>"`
/// so login init runs and PATH/env is correct (claude, codex, asdf, brew, etc.).
enum PtyService {
    static func defaultShell() -> String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Default-shell tab. We wrap in a login-shell `clear; exec` so any
    /// `Last login: …` / `You have mail.` motd-style noise printed while
    /// sourcing the user's profile gets wiped before the inner interactive
    /// shell hands the prompt over to the user.
    static func defaultShellConfig(cwd: URL) -> SurfaceConfig {
        let shell = defaultShell()
        let cmd = "\(shell) -lc 'clear; exec \(shell) -i'"
        return SurfaceConfig(command: cmd, workingDirectory: cwd, env: [:])
    }

    /// Spawn a specific command via the user's login shell.
    /// We pass the whole "$SHELL -ilc <cmd>" line as a single string in the
    /// surface config's `command` field; ghostty splits it argv-style.
    /// `-i` forces the shell to source `.zshrc`/`.bashrc` even though we
    /// immediately run a `-c` command — without it, tools that add
    /// themselves to PATH from the rc file (npm globals, volta, asdf, nvm,
    /// pyenv, …) aren't found and you get `command not found: claude`.
    /// `clear;` runs after profiles finish so banner output is gone before
    /// the user's command paints its UI.
    static func quickLaunchConfig(_ ql: QuickLaunch, cwd: URL) -> SurfaceConfig {
        let shell = defaultShell()
        let escaped = ql.command.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "\(shell) -ilc 'clear; \(escaped)'"
        return SurfaceConfig(command: cmd, workingDirectory: cwd, env: [:])
    }
}
