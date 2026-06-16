import Foundation

/// Resolves a `QuickLaunch` (or "+") into a SurfaceConfig that GhosttyTerminalView
/// can hand to ghostty_surface_new. Wraps user commands in `$SHELL -lc "<cmd>"`
/// so login init runs and PATH/env is correct (claude, codex, asdf, brew, etc.).
enum PtyService {
    static func defaultShell() -> String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Environment hints that make this embedded Ghostty surface behave like
    /// a real color-capable terminal for CLI tools. Ghostty owns `TERM`; these
    /// are the extra markers common macOS/BSD tools and truecolor apps look at.
    static func terminalEnvironment() -> [String: String] {
        var env: [String: String] = [
            "CLICOLOR": "1",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "AgenticIDE",
            "TERM_PROGRAM_VERSION": appVersion(),
            // Socket the `agentide` helper talks to so a cell's agent can
            // drive/observe sibling cells.
            "AGENTIDE_SOCK": AgentBridge.socketURL.path
        ]
        let inherited = ProcessInfo.processInfo.environment
        if let value = inherited["LSCOLORS"], !value.isEmpty {
            env["LSCOLORS"] = value
        }
        if let value = inherited["LS_COLORS"], !value.isEmpty {
            env["LS_COLORS"] = value
        }
        return env
    }

    /// Default-shell tab. We wrap in a login-shell `clear; exec` so any
    /// `Last login: …` / `You have mail.` motd-style noise printed while
    /// sourcing the user's profile gets wiped before the inner interactive
    /// shell hands the prompt over to the user.
    static func defaultShellConfig(cwd: URL) -> SurfaceConfig {
        let shell = defaultShell()
        let cmd = "\(shell) -lc '\(terminalBootstrapCommand()); clear; exec \(shell) -i'"
        return SurfaceConfig(command: cmd, workingDirectory: cwd, env: terminalEnvironment())
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
        let cmd = "\(shell) -ilc '\(terminalBootstrapCommand()); clear; \(escaped)'"
        return SurfaceConfig(command: cmd, workingDirectory: cwd, env: terminalEnvironment())
    }

    /// Remove inherited process flags that intentionally suppress color.
    /// The Codex runtime sets `NO_COLOR=1`; if AgenticIDE inherits that while
    /// being launched from this development session, every child CLI inside
    /// the embedded terminal is forced into monochrome mode.
    private static func terminalBootstrapCommand() -> String {
        // Also prepend the bridge helper's bin dir to PATH (after the login
        // profile has run) so `agentide` is available in every cell.
        let bin = AgentBridge.binDirectoryURL.path
        return "unset NO_COLOR; export PATH=\"\(bin):$PATH\""
    }

    /// Existing saved sessions contain the full command line that was built
    /// before we stripped `NO_COLOR`. Patch those command strings on restore
    /// so users don't have to close and recreate every tab after upgrading.
    static func commandEnsuringTerminalBootstrap(_ command: String?) -> String? {
        guard let command, !command.contains(terminalBootstrapCommand()) else {
            return command
        }
        guard let insertionPoint = command.firstIndex(of: "'") else {
            return command
        }
        var migrated = command
        migrated.insert(contentsOf: "\(terminalBootstrapCommand()); ", at: migrated.index(after: insertionPoint))
        return migrated
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

    private static func appVersion() -> String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty {
            return version
        }
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !build.isEmpty {
            return build
        }
        return "dev"
    }
}
