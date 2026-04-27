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
        let augmented = augmentedCommand(ql.command)
        let escaped = augmented.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "\(shell) -ilc 'clear; \(escaped)'"
        return SurfaceConfig(command: cmd, workingDirectory: cwd, env: [:])
    }

    /// If the user has flipped on a "dangerous" toggle in Settings and the
    /// command's first token is `claude` or `codex`, append the matching
    /// auto-accept flag. Idempotent — won't duplicate an existing flag.
    static func augmentedCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard let firstToken = trimmed.split(separator: " ", maxSplits: 1).first else {
            return command
        }
        let executable = (String(firstToken) as NSString).lastPathComponent

        if executable == "claude",
           AppSettings.claudeDangerousSkipPermissions,
           !command.contains("--dangerously-skip-permissions") {
            return command + " --dangerously-skip-permissions"
        }
        if executable == "codex",
           AppSettings.codexDangerousBypass,
           !command.contains("--dangerously-bypass-approvals-and-sandbox") {
            return command + " --dangerously-bypass-approvals-and-sandbox"
        }
        return command
    }
}
