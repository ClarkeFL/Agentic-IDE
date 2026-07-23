import Foundation
import Observation
import OSLog

/// One provider row in the sidebar usage footer.
struct ProviderUsage: Identifiable, Equatable, Sendable {
    enum Provider: String, CaseIterable, Identifiable, Sendable {
        case claude
        case fable
        case codex
        case grok

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .claude: return "Claude"
            case .fable:  return "Fable"
            case .codex:  return "Codex"
            case .grok:   return "Grok"
            }
        }

        /// Brand icon key for `quickLaunchIcon`, or nil for a custom mark.
        var brandIcon: String? {
            switch self {
            case .claude: return "brand:claude"
            case .fable:  return nil // compact "F" mark in UsageBar
            case .codex:  return "brand:codex"
            case .grok:   return nil
            }
        }

        /// Single-letter mark when `brandIcon` is nil (Fable / Grok).
        var letterMark: String? {
            switch self {
            case .fable: return "F"
            case .grok:  return "G"
            default:     return nil
            }
        }

        var usageURL: URL? {
            switch self {
            case .claude, .fable:
                // Fable is Anthropic-scoped weekly; same usage dashboard as Claude.
                return URL(string: "https://claude.ai/settings/usage")
            case .codex:
                return URL(string: "https://chatgpt.com/codex/cloud/settings/analytics#usage")
            case .grok:
                return URL(string: "https://grok.com")
            }
        }
    }

    var id: String { provider.id }
    var provider: Provider
    /// Weekly plan utilization 0…100. nil = unknown / not available.
    var weeklyPercent: Double?
    /// When the weekly window resets (provider-local interpretation).
    var weeklyResetsAt: Date?
    /// True when the short (≈5h) window is near exhaustion.
    var shortWindowWarning: Bool
    /// Tooltip detail for the short-window warning (e.g. "5h 87% · resets in 1h").
    var shortWindowDetail: String?
    /// Human status when weeklyPercent is nil ("—", "sign in", "error", …).
    var placeholder: String
    /// When the *provider* last produced this sample (log/event/API time),
    /// not when AgenticIDE re-read it. Used for staleness.
    var sampledAt: Date?

    /// Sample older than this is drawn as last-known (empty dashed bar + `81%*`).
    static let staleAfter: TimeInterval = 6 * 60 * 60

    /// True when we have a % but the source sample is older than `staleAfter`.
    var isStale: Bool {
        guard weeklyPercent != nil, let sampledAt else { return false }
        return Date().timeIntervalSince(sampledAt) > Self.staleAfter
    }

    static func empty(_ provider: Provider, placeholder: String = "—") -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            weeklyPercent: nil,
            weeklyResetsAt: nil,
            shortWindowWarning: false,
            shortWindowDetail: nil,
            placeholder: placeholder,
            sampledAt: nil
        )
    }
}

/// Polls each AI provider's plan-level weekly usage for the sidebar footer.
///
/// Sources:
/// - **Claude** — Anthropic OAuth usage API (same data as `/usage`), using the
///   token Claude Code already stores in the login Keychain.
/// - **Fable** — Anthropic `limits[]` entry with `weekly_scoped` + model
///   display name "Fable" (separate weekly bucket from general Claude).
/// - **Codex** — live ChatGPT usage API (`backend-api/wham/usage`) using the
///   OAuth token opencode stores in `~/.local/share/opencode/auth.json`;
///   falls back to the latest `rate_limits` block in `~/.codex/sessions`
///   rollouts (Codex CLI, updated after each turn).
/// - **Grok** — latest `billing: fetched credits config` line in
///   `~/.grok/logs/unified.jsonl` (written whenever the Grok CLI refreshes
///   SuperGrok credits). No public HTTP endpoint for plan % yet.
///
/// The short (≈5 hour) windows are **not** shown as bars — only a warning
/// icon when utilization crosses `shortWindowWarnThreshold`.
@Observable
final class UsageMonitor {
    private(set) var claude: ProviderUsage = .empty(.claude)
    private(set) var fable: ProviderUsage = .empty(.fable)
    private(set) var codex: ProviderUsage = .empty(.codex)
    private(set) var grok: ProviderUsage = .empty(.grok, placeholder: "—")

    /// Rows in display order (Fable sits under Claude — same API, own quota).
    var rows: [ProviderUsage] { [claude, fable, codex, grok] }

    /// Fire the short-window warning at this utilization (percent).
    static let shortWindowWarnThreshold: Double = 80
    /// Same threshold as `ProviderUsage.staleAfter` (last-known display).
    static let staleAfter: TimeInterval = ProviderUsage.staleAfter

    @ObservationIgnored
    private var timer: Timer?
    @ObservationIgnored
    private let log = Logger(subsystem: "com.fabio.AgenticIDE", category: "UsageMonitor")
    @ObservationIgnored
    private let queue = DispatchQueue(label: "com.fabio.AgenticIDE.UsageMonitor", qos: .utility)

    /// Poll interval. Claude's usage endpoint rate-limits when hammered;
    /// Codex is local file IO and cheap. One shared cadence is enough.
    private static let pollInterval: TimeInterval = 90

    init() { start() }

    deinit { timer?.invalidate() }

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Manual refresh (e.g. click / menu later).
    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let anthropic = self.fetchAnthropic()
            let codex = self.fetchCodex()
            let grok = self.fetchGrok()
            DispatchQueue.main.async {
                self.claude = anthropic.claude
                self.fable = anthropic.fable
                self.codex = codex
                self.grok = grok
            }
        }
    }

    // MARK: - Claude + Fable (same Anthropic OAuth usage response)

    private struct AnthropicUsage {
        var claude: ProviderUsage
        var fable: ProviderUsage
    }

    private func fetchAnthropic() -> AnthropicUsage {
        guard let token = Self.claudeAccessToken() else {
            return AnthropicUsage(
                claude: .empty(.claude, placeholder: "login"),
                fable: .empty(.fable, placeholder: "login")
            )
        }

        var request = URLRequest(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.0.32", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 12

        do {
            let (data, response) = try Self.syncData(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log.debug("Claude usage HTTP \(http.statusCode)")
                let placeholder: String
                if http.statusCode == 401 || http.statusCode == 403 {
                    placeholder = "login"
                } else if http.statusCode == 429 {
                    placeholder = "wait"
                } else {
                    placeholder = "err"
                }
                return AnthropicUsage(
                    claude: .empty(.claude, placeholder: placeholder),
                    fable: .empty(.fable, placeholder: placeholder)
                )
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return AnthropicUsage(
                    claude: .empty(.claude, placeholder: "err"),
                    fable: .empty(.fable, placeholder: "err")
                )
            }
            return Self.parseAnthropic(json)
        } catch {
            log.debug("Claude usage fetch failed: \(error.localizedDescription, privacy: .public)")
            return AnthropicUsage(
                claude: .empty(.claude, placeholder: "err"),
                fable: .empty(.fable, placeholder: "err")
            )
        }
    }

    private static func parseAnthropic(_ json: [String: Any]) -> AnthropicUsage {
        let weekly = window(from: json["seven_day"])
        let fiveHour = window(from: json["five_hour"])

        // Claude short-window = global 5h / unscoped session only.
        // Fable has its own weekly row — do not fold it into Claude's warning.
        var shortPercent = fiveHour?.percent
        var shortResets = fiveHour?.resetsAt
        var fableWeekly: ParsedWindow?

        if let limits = json["limits"] as? [[String: Any]] {
            for limit in limits {
                let kind = (limit["kind"] as? String ?? "").lowercased()
                let scopeName = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                    ?? ""
                let isFable = scopeName.localizedCaseInsensitiveContains("fable")

                if isFable {
                    // Prefer weekly_scoped; accept any Fable limit with a %.
                    guard let p = number(limit["percent"]) else { continue }
                    let isWeekly = kind.contains("weekly") || kind.contains("seven")
                    if isWeekly || fableWeekly == nil {
                        fableWeekly = ParsedWindow(
                            percent: p,
                            resetsAt: parseISO8601(limit["resets_at"] as? String)
                        )
                    }
                    continue
                }

                let isSession = kind.contains("session") || kind.contains("five")
                guard isSession, shortPercent == nil else { continue }
                guard let p = number(limit["percent"]) else { continue }
                shortPercent = p
                shortResets = parseISO8601(limit["resets_at"] as? String) ?? shortResets
            }
        }

        let warn = (shortPercent ?? 0) >= shortWindowWarnThreshold
        let detail: String? = {
            guard let p = shortPercent else { return nil }
            var parts = [String(format: "5h %.0f%%", p)]
            if let resets = shortResets {
                parts.append("resets \(relativeReset(resets))")
            }
            return parts.joined(separator: " · ")
        }()

        let now = Date() // live API response
        let claude = ProviderUsage(
            provider: .claude,
            weeklyPercent: weekly?.percent,
            weeklyResetsAt: weekly?.resetsAt,
            shortWindowWarning: warn,
            shortWindowDetail: detail,
            placeholder: "—",
            sampledAt: now
        )
        let fable: ProviderUsage
        if let fableWeekly {
            fable = ProviderUsage(
                provider: .fable,
                weeklyPercent: fableWeekly.percent,
                weeklyResetsAt: fableWeekly.resetsAt,
                shortWindowWarning: false,
                shortWindowDetail: nil,
                placeholder: "—",
                sampledAt: now
            )
        } else {
            fable = .empty(.fable, placeholder: "—")
        }
        return AnthropicUsage(claude: claude, fable: fable)
    }

    /// Reads Claude Code's OAuth access token from the login Keychain.
    private static func claudeAccessToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    // MARK: - Codex

    private func fetchCodex() -> ProviderUsage {
        if let live = fetchCodexLive() { return live }
        guard let limits = Self.latestCodexRateLimits() else {
            return .empty(.codex, placeholder: "—")
        }

        let windows = [limits.primary, limits.secondary].compactMap { $0 }
        // Weekly ≈ 7 days (10080 min); also accept any window ≥ 1 day.
        let weekly = windows
            .filter { $0.windowMinutes >= 24 * 60 }
            .max(by: { $0.windowMinutes < $1.windowMinutes })
        // Short window ≈ 5h (300 min); anything under 12h counts.
        let short = windows
            .filter { $0.windowMinutes > 0 && $0.windowMinutes < 12 * 60 }
            .min(by: { $0.windowMinutes < $1.windowMinutes })

        let warn = (short?.usedPercent ?? 0) >= Self.shortWindowWarnThreshold
        let detail: String? = {
            guard let short else { return nil }
            var parts = [String(format: "5h %.0f%%", short.usedPercent)]
            if let resets = short.resetsAt {
                parts.append("resets \(Self.relativeReset(resets))")
            }
            return parts.joined(separator: " · ")
        }()

        return ProviderUsage(
            provider: .codex,
            weeklyPercent: weekly?.usedPercent,
            weeklyResetsAt: weekly?.resetsAt,
            shortWindowWarning: warn,
            shortWindowDetail: detail,
            placeholder: "—",
            sampledAt: limits.sampledAt ?? Date()
        )
    }

    /// Live plan usage from the ChatGPT backend, authenticated with the
    /// OAuth token opencode keeps in `~/.local/share/opencode/auth.json`.
    /// Returns nil (→ file-scan fallback) when there's no valid token or
    /// the request fails.
    private func fetchCodexLive() -> ProviderUsage? {
        guard let auth = Self.openCodeOpenAIAuth() else { return nil }

        var request = URLRequest(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(auth.access)", forHTTPHeaderField: "Authorization")
        if let account = auth.accountId {
            request.setValue(account, forHTTPHeaderField: "chatgpt-account-id")
        }
        request.timeoutInterval = 12

        do {
            let (data, response) = try Self.syncData(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rateLimit = json["rate_limit"] as? [String: Any] else {
                log.debug("Codex live usage unavailable, falling back to rollouts")
                return nil
            }

            let weekly = Self.parseWhamWindow(rateLimit["primary_window"] as? [String: Any])
            let short = Self.parseWhamWindow(rateLimit["secondary_window"] as? [String: Any])

            let warn = (short?.usedPercent ?? 0) >= Self.shortWindowWarnThreshold
            let detail: String? = short.map { s in
                var parts = [String(format: "5h %.0f%%", s.usedPercent)]
                if let resets = s.resetsAt {
                    parts.append("resets \(Self.relativeReset(resets))")
                }
                return parts.joined(separator: " · ")
            }

            return ProviderUsage(
                provider: .codex,
                weeklyPercent: weekly?.usedPercent,
                weeklyResetsAt: weekly?.resetsAt,
                shortWindowWarning: warn,
                shortWindowDetail: detail,
                placeholder: "—",
                sampledAt: Date() // live API response
            )
        } catch {
            log.debug("Codex live usage fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func parseWhamWindow(_ dict: [String: Any]?) -> CodexWindow? {
        guard let dict, let percent = number(dict["used_percent"]) else { return nil }
        let seconds = number(dict["limit_window_seconds"]) ?? 0
        var resets: Date?
        if let ts = number(dict["reset_at"]) {
            resets = Date(timeIntervalSince1970: ts)
        }
        return CodexWindow(
            usedPercent: percent,
            windowMinutes: Int(seconds / 60),
            resetsAt: resets
        )
    }

    private struct OpenCodeOpenAIAuth {
        var access: String
        var accountId: String?
    }

    /// Reads opencode's OpenAI OAuth token; nil when missing or expired
    /// (opencode refreshes it whenever it's used, so we never refresh here).
    private static func openCodeOpenAIAuth() -> OpenCodeOpenAIAuth? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/opencode/auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let openai = json["openai"] as? [String: Any],
              let access = openai["access"] as? String,
              !access.isEmpty else {
            return nil
        }
        if let expiresMs = number(openai["expires"]),
           Date(timeIntervalSince1970: expiresMs / 1000) < Date() {
            return nil
        }
        return OpenCodeOpenAIAuth(
            access: access,
            accountId: openai["accountId"] as? String
        )
    }

    private struct CodexWindow {
        var usedPercent: Double
        var windowMinutes: Int
        var resetsAt: Date?
    }

    private struct CodexRateLimits {
        var primary: CodexWindow?
        var secondary: CodexWindow?
        /// Timestamp of the session event that carried these limits.
        var sampledAt: Date?
    }

    /// Walk recent day folders under `~/.codex/sessions/YYYY/MM/DD` and
    /// return the newest `rate_limits` payload found. Caps work so a huge
    /// history directory doesn't stall the poller.
    private static func latestCodexRateLimits() -> CodexRateLimits? {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return nil }

        // Prefer path-ordered recent days (YYYY/MM/DD).
        var dayDirs: [URL] = []
        if let years = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for year in years.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).prefix(2) {
                guard let months = try? fm.contentsOfDirectory(
                    at: year,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for month in months.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).prefix(2) {
                    guard let days = try? fm.contentsOfDirectory(
                        at: month,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }
                    dayDirs.append(contentsOf:
                        days.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).prefix(5)
                    )
                }
            }
        }

        var candidates: [URL] = []
        for day in dayDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: day,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            let jsonl = files.filter { $0.pathExtension == "jsonl" }
            candidates.append(contentsOf: jsonl)
        }

        // Newest files first.
        candidates.sort { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return da > db
        }

        for file in candidates.prefix(40) {
            if let limits = scanCodexFile(file) {
                return limits
            }
        }
        return nil
    }

    /// Scan a rollout file from the end — rate_limits land on token_count
    /// events, which appear frequently near the tail.
    private static func scanCodexFile(_ url: URL) -> CodexRateLimits? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let window = min(size, 512 * 1024)
        let start = size > window ? size - window : 0
        do {
            try handle.seek(toOffset: start)
        } catch {
            return nil
        }
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Walk lines newest-first.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("rate_limits") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let payload = obj["payload"] as? [String: Any]
            let rateLimits = (payload?["rate_limits"] as? [String: Any])
                ?? (obj["rate_limits"] as? [String: Any])
            guard let rateLimits else { continue }
            let sampledAt = parseISO8601(obj["timestamp"] as? String)
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate)
            return CodexRateLimits(
                primary: parseCodexWindow(rateLimits["primary"] as? [String: Any]),
                secondary: parseCodexWindow(rateLimits["secondary"] as? [String: Any]),
                sampledAt: sampledAt
            )
        }
        return nil
    }

    private static func parseCodexWindow(_ dict: [String: Any]?) -> CodexWindow? {
        guard let dict else { return nil }
        guard let percent = number(dict["used_percent"]) else { return nil }
        let minutes: Int
        if let m = dict["window_minutes"] as? Int {
            minutes = m
        } else if let m = dict["window_minutes"] as? Double {
            minutes = Int(m)
        } else {
            minutes = 0
        }
        var resets: Date?
        if let ts = dict["resets_at"] as? Double {
            resets = Date(timeIntervalSince1970: ts)
        } else if let ts = dict["resets_at"] as? Int {
            resets = Date(timeIntervalSince1970: TimeInterval(ts))
        }
        return CodexWindow(usedPercent: percent, windowMinutes: minutes, resetsAt: resets)
    }

    // MARK: - Grok

    private func fetchGrok() -> ProviderUsage {
        guard let sample = Self.latestGrokBilling() else {
            return .empty(.grok, placeholder: "—")
        }
        return ProviderUsage(
            provider: .grok,
            weeklyPercent: sample.percent,
            weeklyResetsAt: sample.periodEnd,
            shortWindowWarning: false,
            shortWindowDetail: nil,
            placeholder: "—",
            // Log line time — not "when we re-read the file".
            sampledAt: sample.loggedAt
        )
    }

    private struct GrokBillingSample {
        var percent: Double
        var periodEnd: Date?
        var loggedAt: Date?
    }

    /// Tail `~/.grok/logs/unified.jsonl` for the newest
    /// `billing: fetched credits config` event. The Grok CLI writes
    /// `creditUsagePercent` (0–100) and the weekly period end there on
    /// each credits refresh.
    private static func latestGrokBilling() -> GrokBillingSample? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grok/logs/unified.jsonl")
        guard FileManager.default.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        // Billing events are sparse; 2 MB of tail covers many sessions.
        let window = min(size, 2 * 1024 * 1024)
        let start = size > window ? size - window : 0
        do { try handle.seek(toOffset: start) } catch { return nil }
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("creditUsagePercent")
                    || line.contains("fetched credits config") else {
                continue
            }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            // Shape: { msg, ctx: { config: { creditUsagePercent, billingPeriodEnd, … } } }
            let ctx = obj["ctx"] as? [String: Any]
            let config = (ctx?["config"] as? [String: Any])
                ?? (obj["config"] as? [String: Any])
            guard let config,
                  let percent = number(config["creditUsagePercent"]) else {
                continue
            }

            var periodEnd: Date?
            if let end = config["billingPeriodEnd"] as? String {
                periodEnd = parseISO8601(end)
            } else if let period = config["currentPeriod"] as? [String: Any],
                      let end = period["end"] as? String {
                periodEnd = parseISO8601(end)
            }

            let loggedAt = parseISO8601(obj["ts"] as? String)
            return GrokBillingSample(percent: percent, periodEnd: periodEnd, loggedAt: loggedAt)
        }
        return nil
    }

    // MARK: - Helpers

    private struct ParsedWindow {
        var percent: Double
        var resetsAt: Date?
    }

    private static func window(from any: Any?) -> ParsedWindow? {
        guard let dict = any as? [String: Any] else { return nil }
        guard let percent = number(dict["utilization"]) ?? number(dict["used_percentage"])
                ?? number(dict["percent"]) else {
            return nil
        }
        let resets = parseISO8601(dict["resets_at"] as? String)
        return ParsedWindow(percent: percent, resetsAt: resets)
    }

    private static func number(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private static func parseISO8601(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func relativeReset(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "soon" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds > 48 * 3600 ? [.day, .hour] : [.hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        return "in \(formatter.string(from: seconds) ?? "…")"
    }

    private static func syncData(for request: URLRequest) throws -> (Data, URLResponse) {
        let box = SyncBox()
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            sem.signal()
        }
        task.resume()
        let result = sem.wait(timeout: .now() + 15)
        if result == .timedOut {
            task.cancel()
            throw URLError(.timedOut)
        }
        if let error = box.error { throw error }
        guard let data = box.data, let response = box.response else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }

    private final class SyncBox: @unchecked Sendable {
        var data: Data?
        var response: URLResponse?
        var error: Error?
    }
}
