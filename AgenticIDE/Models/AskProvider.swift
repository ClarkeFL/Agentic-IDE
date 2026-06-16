import Foundation

/// Which CLI the Ask overlay talks to. Both `claude` and `codex` are spawned
/// in their non-interactive "print" modes; the picker in the composer lets the
/// user flip between them per-message. Gemini etc. aren't modelled because the
/// box this ships to doesn't have them installed — add a case here (plus a
/// `models` / `effortLevels` / `command` arm) if that changes.
enum AskProvider: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// SF Symbol shown in the provider chip + the assistant avatar.
    var symbol: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    // MARK: - Models

    /// Selectable models. The first entry is always the "let the CLI decide"
    /// option (no `--model` flag) so the invocation is valid even if the named
    /// aliases drift between CLI versions.
    var models: [AskModel] {
        switch self {
        case .claude:
            return [
                AskModel(id: "auto", label: "Auto", flag: nil),
                AskModel(id: "opus", label: "Opus", flag: "opus"),
                AskModel(id: "sonnet", label: "Sonnet", flag: "sonnet"),
                AskModel(id: "haiku", label: "Haiku", flag: "haiku"),
            ]
        case .codex:
            return [
                AskModel(id: "auto", label: "Default", flag: nil),
                AskModel(id: "gpt-5.5", label: "GPT-5.5", flag: "gpt-5.5"),
                AskModel(id: "gpt-5-codex", label: "GPT-5 Codex", flag: "gpt-5-codex"),
            ]
        }
    }

    /// Reasoning effort levels this provider understands. Both start with
    /// `.auto` (no flag → CLI/profile default). Claude additionally exposes
    /// `max`; Codex tops out at `xhigh`.
    var effortLevels: [AskEffort] {
        switch self {
        case .claude: return [.auto, .low, .medium, .high, .xhigh, .max]
        case .codex:  return [.auto, .low, .medium, .high, .xhigh]
        }
    }

    var defaultModel: AskModel { models[0] }
    var defaultEffort: AskEffort { .auto }

    /// Resolve a persisted model id back to one of this provider's models,
    /// falling back to the default when the id belongs to another provider.
    func model(id: String?) -> AskModel {
        guard let id, let match = models.first(where: { $0.id == id }) else { return defaultModel }
        return match
    }

    /// Clamp an effort to one this provider supports (e.g. Claude's `.max`
    /// degrades to `.xhigh` when the user switches to Codex).
    func effort(_ effort: AskEffort) -> AskEffort {
        if effortLevels.contains(effort) { return effort }
        // Walk down the ladder to the strongest level this provider allows.
        let order: [AskEffort] = [.max, .xhigh, .high, .medium, .low, .auto]
        guard let from = order.firstIndex(of: effort) else { return defaultEffort }
        for candidate in order[from...] where effortLevels.contains(candidate) {
            return candidate
        }
        return defaultEffort
    }

    // MARK: - Command

    /// Build the prefix invocation (everything before the quoted prompt) that
    /// `AskService` hands to the login shell. `dangerous` folds in the user's
    /// per-CLI "skip safety prompts" preference so a quick question doesn't
    /// stall on an approval prompt that print mode can't surface.
    func command(model: AskModel, effort: AskEffort, dangerous: Bool) -> String {
        switch self {
        case .claude:
            var parts = ["claude", "-p"]
            if let flag = model.flag { parts += ["--model", flag] }
            if let level = effort.flagValue { parts += ["--effort", level] }
            if dangerous { parts.append("--dangerously-skip-permissions") }
            return parts.joined(separator: " ")
        case .codex:
            // `--skip-git-repo-check`: the Ask overlay runs in $HOME, which
            // isn't a git repo, and `codex exec` otherwise refuses to start.
            var parts = ["codex", "exec", "--skip-git-repo-check"]
            if let flag = model.flag { parts += ["-m", flag] }
            if let level = effort.flagValue { parts += ["-c", "model_reasoning_effort=\"\(level)\""] }
            if dangerous {
                parts.append("--dangerously-bypass-approvals-and-sandbox")
            } else {
                // Quick Q&A only ever needs to read; a read-only sandbox keeps
                // a non-interactive `exec` from stalling on a write approval.
                parts += ["-s", "read-only"]
            }
            return parts.joined(separator: " ")
        }
    }

    /// Build the full invocation including any attached images. Returns the
    /// shell command prefix and the (possibly augmented) prompt that
    /// `AskService` appends as a quoted positional argument.
    ///
    /// The two CLIs take images differently: Codex has a native `-i` flag,
    /// while Claude's print mode has none — but its Read tool ingests a local
    /// image as vision input, so we hand Claude the paths inside the prompt.
    func invocation(prompt: String, model: AskModel, effort: AskEffort,
                    dangerous: Bool, imagePaths: [String]) -> (command: String, prompt: String) {
        let base = command(model: model, effort: effort, dangerous: dangerous)
        guard !imagePaths.isEmpty else { return (base, prompt) }
        switch self {
        case .claude:
            let list = imagePaths.map { "- \($0)" }.joined(separator: "\n")
            return (base, "\(prompt)\n\nView the attached image file(s):\n\(list)")
        case .codex:
            // `-i/--image <FILE>...` is variadic and would greedily eat the
            // positional prompt that AskService appends after it (yielding
            // "No prompt provided via stdin"). The `--image=<path>` form binds
            // exactly one value per occurrence, so the prompt stays positional.
            let flags = imagePaths.map { "--image='\(Self.escapeForShell($0))'" }.joined(separator: " ")
            return ("\(base) \(flags)", prompt)
        }
    }

    private static func escapeForShell(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}

/// A single model choice for a provider. `flag` is the value passed to the
/// CLI's model flag (`--model` / `-m`); `nil` means "omit the flag entirely"
/// so the CLI uses its configured default.
struct AskModel: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let flag: String?
}

/// Reasoning-effort level. Maps onto Claude's `--effort` and Codex's
/// `model_reasoning_effort` config key. `.auto` emits no flag.
enum AskEffort: String, CaseIterable, Identifiable, Sendable {
    case auto
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:   return "Auto"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        case .xhigh:  return "X-High"
        case .max:    return "Max"
        }
    }

    /// Value handed to the CLI; `nil` for `.auto` (no flag).
    var flagValue: String? {
        self == .auto ? nil : rawValue
    }
}
