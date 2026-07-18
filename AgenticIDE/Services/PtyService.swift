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
    /// Intentionally minimal — advertise truecolor, don't force color on every
    /// CLI (`FORCE_COLOR` etc. over-steers tools like Grok that have their own
    /// theme). Inherited `NO_COLOR` is stripped in the shell bootstrap instead.
    ///
    /// `TERM_PROGRAM` is `ghostty` (not `AgenticIDE`) on purpose: Claude Code's
    /// color/theme stack only special-cases a short list (ghostty, iTerm.app,
    /// Apple_Terminal, …). An unknown program name is why Claude alone went
    /// monochrome while Grok/opencode/etc. still painted fine in the same cell.
    /// Identity for our tooling lives in `AGENTIDE_*` / the sock path instead.
    static func terminalEnvironment() -> [String: String] {
        var env: [String: String] = [
            "CLICOLOR": "1",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "ghostty",
            "TERM_PROGRAM_VERSION": appVersion(),
            // Socket the `agentide` helper talks to so a cell's agent can
            // drive/observe sibling cells.
            "AGENTIDE_SOCK": AgentBridge.socketURL.path,
            "AGENTIDE": "1",
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
        var env = terminalEnvironment()
        // Prefer the configured port so frameworks that honor PORT (Vite, Next,
        // Rails, Flask, …) bind where the agent/UI expect.
        if let port = ql.port, port > 0, port <= 65535 {
            env["PORT"] = String(port)
            env["AGENTIDE_PORT"] = String(port)
        }
        return SurfaceConfig(command: cmd, workingDirectory: cwd, env: env)
    }

    /// Strip inherited monochrome kill-switches so chalk/Ink CLIs (notably
    /// Claude) can use color when the host was launched from an agent harness.
    /// Keep this minimal — no force-on exports (`FORCE_COLOR=1`) that recolor
    /// tools with their own themes (Grok, etc.).
    ///
    /// Live Claude cells under AgenticIDE were observed with `FORCE_COLOR=0`
    /// + `CLICOLOR_FORCE=0` in their environ; chalk treats `FORCE_COLOR=0` as
    /// hard monochrome even with `COLORTERM=truecolor`.
    private static func terminalBootstrapCommand() -> String {
        // Also prepend the bridge helper's bin dir to PATH (after the login
        // profile has run) so `agentide` is available in every cell.
        let bin = AgentBridge.binDirectoryURL.path
        // Unset force-OFF flags only; leave FORCE_COLOR=1 alone if a user set it.
        return "unset NO_COLOR NODE_DISABLE_COLORS PIP_NO_COLOR PYTHON_DISABLE_COLORS; "
            + "[ \"${FORCE_COLOR-}\" = 0 ] && unset FORCE_COLOR; "
            + "[ \"${CLICOLOR_FORCE-}\" = 0 ] && unset CLICOLOR_FORCE; "
            + "[ \"${NPM_CONFIG_COLOR-}\" = false ] && unset NPM_CONFIG_COLOR; "
            + "[ \"${CARGO_TERM_COLOR-}\" = never ] && unset CARGO_TERM_COLOR; "
            + "export PATH=\"\(bin):$PATH\""
    }

    /// Existing saved sessions contain the full command line that was built
    /// with an older bootstrap. Patch those on restore so users don't have to
    /// close and recreate every tab after upgrading.
    static func commandEnsuringTerminalBootstrap(_ command: String?) -> String? {
        guard let command else { return nil }
        let bootstrap = terminalBootstrapCommand()
        if command.contains(bootstrap) { return command }

        // Strip any older bootstrap prefix we used to inject, then install
        // the current one. Avoids stacking `unset NO_COLOR; …; unset NO_COLOR; …`.
        var body = command
        let bin = AgentBridge.binDirectoryURL.path
        let legacyPrefixes = [
            // 2026-07 over-broad force-on export (FORCE_COLOR, CLICOLOR_FORCE, …)
            "unset NO_COLOR PIP_NO_COLOR PYTHON_DISABLE_COLORS; "
                + "export CLICOLOR=1 CLICOLOR_FORCE=1 FORCE_COLOR=1 COLORTERM=truecolor "
                + "NPM_CONFIG_COLOR=true CARGO_TERM_COLOR=always; "
                + "export PATH=\"\(bin):$PATH\"; ",
            // 2026-07 FORCE_COLOR=0 scrub (current-shaped, keep last for match)
            "unset NO_COLOR NODE_DISABLE_COLORS PIP_NO_COLOR PYTHON_DISABLE_COLORS; "
                + "[ \"${FORCE_COLOR-}\" = 0 ] && unset FORCE_COLOR; "
                + "[ \"${CLICOLOR_FORCE-}\" = 0 ] && unset CLICOLOR_FORCE; "
                + "[ \"${NPM_CONFIG_COLOR-}\" = false ] && unset NPM_CONFIG_COLOR; "
                + "[ \"${CARGO_TERM_COLOR-}\" = never ] && unset CARGO_TERM_COLOR; "
                + "export PATH=\"\(bin):$PATH\"; ",
            "unset NO_COLOR; export PATH=\"\(bin):$PATH\"; ",
            "unset NO_COLOR; ",
        ]
        for legacy in legacyPrefixes {
            if let range = body.range(of: legacy) {
                body.removeSubrange(range)
                break
            }
        }
        guard let insertionPoint = body.firstIndex(of: "'") else { return body }
        var migrated = body
        migrated.insert(contentsOf: "\(bootstrap); ", at: migrated.index(after: insertionPoint))
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
