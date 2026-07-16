import Foundation
import Observation
import OSLog

/// One provider row in the sidebar usage footer.
struct ProviderUsage: Identifiable, Equatable, Sendable {
    enum Provider: String, CaseIterable, Identifiable, Sendable {
        case claude
        case codex
        case grok

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .claude: return "Claude"
            case .codex:  return "Codex"
            case .grok:   return "Grok"
            }
        }

        /// Brand icon key for `quickLaunchIcon`, or nil for a custom mark.
        var brandIcon: String? {
            switch self {
            case .claude: return "brand:claude"
            case .codex:  return "brand:codex"
            case .grok:   return nil
            }
        }

        var usageURL: URL? {
            switch self {
            case .claude:
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
/// - **Codex** — latest `rate_limits` block written into `~/.codex/sessions`
///   rollouts (updated after each turn).
/// - **Grok** — latest `billing: fetched credits config` line in
///   `~/.grok/logs/unified.jsonl` (written whenever the Grok CLI refreshes
///   SuperGrok credits). No public HTTP endpoint for plan % yet.
///
/// The short (≈5 hour) windows are **not** shown as bars — only a warning
/// icon when utilization crosses `shortWindowWarnThreshold`.
@Observable
final class UsageMonitor {
    private(set) var claude: ProviderUsage = .empty(.claude)
    private(set) var codex: ProviderUsage = .empty(.codex)
    private(set) var grok: ProviderUsage = .empty(.grok, placeholder: "—")

    /// Rows in display order.
    var rows: [ProviderUsage] { [claude, codex, grok] }

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
            let claude = self.fetchClaude()
            let codex = self.fetchCodex()
            let grok = self.fetchGrok()
            DispatchQueue.main.async {
                self.claude = claude
                self.codex = codex
                self.grok = grok
            }
        }
    }

    // MARK: - Claude

    private func fetchClaude() -> ProviderUsage {
        guard let token = Self.claudeAccessToken() else {
            return .empty(.claude, placeholder: "login")
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
                if http.statusCode == 401 || http.statusCode == 403 {
                    return .empty(.claude, placeholder: "login")
                }
                if http.statusCode == 429 {
                    return .empty(.claude, placeholder: "wait")
                }
                return .empty(.claude, placeholder: "err")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .empty(.claude, placeholder: "err")
            }
            return Self.parseClaude(json)
        } catch {
            log.debug("Claude usage fetch failed: \(error.localizedDescription, privacy: .public)")
            return .empty(.claude, placeholder: "err")
        }
    }

    private static func parseClaude(_ json: [String: Any]) -> ProviderUsage {
        let weekly = window(from: json["seven_day"])
        let fiveHour = window(from: json["five_hour"])

        // Short-window warning: global 5h, or a Fable-scoped session limit if
        // Anthropic exposes one in `limits[]` (takes the higher pressure).
        var shortPercent = fiveHour?.percent
        var shortResets = fiveHour?.resetsAt
        if let limits = json["limits"] as? [[String: Any]] {
            for limit in limits {
                let kind = (limit["kind"] as? String ?? "").lowercased()
                let scopeName = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                    ?? ""
                let isFable = scopeName.localizedCaseInsensitiveContains("fable")
                let isSession = kind.contains("session") || kind.contains("five")
                guard isSession else { continue }
                guard let p = number(limit["percent"]) else { continue }
                // Fable-scoped session always wins; otherwise fill if missing.
                if isFable || shortPercent == nil {
                    shortPercent = isFable ? max(shortPercent ?? 0, p) : p
                    shortResets = parseISO8601(limit["resets_at"] as? String) ?? shortResets
                }
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

        return ProviderUsage(
            provider: .claude,
            weeklyPercent: weekly?.percent,
            weeklyResetsAt: weekly?.resetsAt,
            shortWindowWarning: warn,
            shortWindowDetail: detail,
            placeholder: "—",
            sampledAt: Date() // live API response
        )
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
