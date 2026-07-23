import AppKit
import SwiftUI

/// Weekly AI plan usage for Claude / Fable / Codex / Grok.
///
/// - `.stacked` — sidebar footer (one provider per row, above CPU/MEM).
/// - `.inline`  — browser agent column footer (providers side-by-side).
///
/// Bars are weekly plan utilization only. A trailing warning glyph appears
/// when that provider's short (≈5h) window is near its cap — Claude and
/// Codex/GPT. Fable is Anthropic's separate weekly-scoped bucket.
///
/// **Stale samples** (source older than 6h): empty dashed track + `81%*` so
/// the last-known value stays visible without looking live.
struct UsageBar: View {
    enum Layout {
        /// One provider per row (sidebar).
        case stacked
        /// Providers in a single horizontal strip (browser column).
        case inline
    }

    @Environment(UsageMonitor.self) private var monitor
    var layout: Layout = .stacked

    var body: some View {
        Group {
            switch layout {
            case .stacked:
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    ForEach(monitor.rows) { row in
                        stackedRow(row)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .inline:
                // Wider browser column: roomy gaps so logo · bar · % chips
                // don't run together (sidebar stays stacked/tighter).
                HStack(spacing: DS.Space.xl) {
                    ForEach(monitor.rows) { row in
                        inlineChip(row)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .help(helpText)
        .contextMenu {
            Button("Refresh Usage") { monitor.refresh() }
            Divider()
            ForEach(monitor.rows) { row in
                if let url = row.provider.usageURL {
                    Button("Open \(row.provider.displayName) Usage…") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    // MARK: - Stacked (sidebar)

    @ViewBuilder
    private func stackedRow(_ row: ProviderUsage) -> some View {
        Button {
            openUsage(for: row)
        } label: {
            HStack(spacing: DS.Space.xs) {
                logo(for: row.provider, stale: row.isStale)
                    .frame(width: 12, height: 12)

                Text(row.provider.displayName)
                    .foregroundStyle(.tertiary)
                    .opacity(row.isStale ? 0.55 : 1)
                    .lineLimit(1)
                    .frame(width: 48, alignment: .leading)

                bar(percent: row.weeklyPercent, stale: row.isStale)
                    .frame(maxWidth: .infinity)

                Text(percentLabel(row))
                    .foregroundStyle(row.isStale
                                     ? Color.primary.opacity(0.45)
                                     : tint(for: row.weeklyPercent))
                    // Room for trailing `*` when last-known.
                    .frame(width: 36, alignment: .trailing)

                warningSlot(row)
                    .frame(width: 12, height: 12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(rowHelp(row))
    }

    // MARK: - Inline (browser)

    /// Compact chip: logo · mini-bar · % · optional ⚠ — equal-width columns.
    @ViewBuilder
    private func inlineChip(_ row: ProviderUsage) -> some View {
        Button {
            openUsage(for: row)
        } label: {
            HStack(spacing: DS.Space.xs) {
                logo(for: row.provider, stale: row.isStale)
                    .frame(width: 12, height: 12)

                bar(percent: row.weeklyPercent, stale: row.isStale)
                    .frame(maxWidth: .infinity)
                    .frame(height: 5)

                Text(percentLabel(row))
                    .foregroundStyle(row.isStale
                                     ? Color.primary.opacity(0.45)
                                     : tint(for: row.weeklyPercent))
                    .lineLimit(1)
                    .frame(minWidth: 32, alignment: .trailing)

                // Reserve a slot so % columns stay aligned when only one
                // provider is warning.
                Group {
                    if row.shortWindowWarning && !row.isStale {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color(red: 0.95, green: 0.75, blue: 0.20))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 10, height: 10)
            }
            .padding(.horizontal, DS.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(rowHelp(row))
        .accessibilityLabel("\(row.provider.displayName) \(percentLabel(row)) weekly")
    }

    // MARK: - Shared

    private func openUsage(for row: ProviderUsage) {
        if let url = row.provider.usageURL {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private func logo(for provider: ProviderUsage.Provider, stale: Bool) -> some View {
        let opacity = stale ? 0.4 : 1.0
        Group {
            if let brand = provider.brandIcon {
                quickLaunchIcon(name: brand, size: 11)
                    .foregroundStyle(.secondary)
            } else if let letter = provider.letterMark {
                // Fable / Grok — no brand asset; compact letter keeps the column aligned.
                Text(letter)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 11, height: 11)
            } else {
                Color.clear.frame(width: 11, height: 11)
            }
        }
        .opacity(opacity)
    }

    /// Live: filled capsule. Stale last-known: dashed empty track (no fill).
    private func bar(percent: Double?, stale: Bool) -> some View {
        GeometryReader { geo in
            if stale {
                // `--------` style: equal dash segments, no utilization fill.
                HStack(spacing: 2) {
                    ForEach(0..<9, id: \.self) { _ in
                        Capsule()
                            .fill(Color.primary.opacity(0.14))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 3)
                .frame(maxHeight: .infinity, alignment: .center)
            } else {
                let track = Color.primary.opacity(0.08)
                let fill = tint(for: percent)
                let p = max(0, min(100, percent ?? 0)) / 100.0
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    if percent != nil {
                        Capsule()
                            .fill(fill.opacity(0.85))
                            .frame(width: max(2, geo.size.width * p))
                    }
                }
            }
        }
        .frame(height: 4)
    }

    @ViewBuilder
    private func warningSlot(_ row: ProviderUsage) -> some View {
        // Don't yell about a 5h window on a sample we no longer treat as live.
        if row.shortWindowWarning && !row.isStale {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(red: 0.95, green: 0.75, blue: 0.20))
                .help(row.shortWindowDetail ?? "5-hour limit nearly reached")
        } else {
            Color.clear
        }
    }

    private func percentLabel(_ row: ProviderUsage) -> String {
        if let p = row.weeklyPercent {
            let base = String(format: "%2.0f%%", p.rounded())
            return row.isStale ? "\(base)*" : base
        }
        return row.placeholder
    }

    private func tint(for percent: Double?) -> Color {
        guard let percent else { return .secondary }
        switch percent {
        case ..<70: return .secondary
        case ..<90: return Color(red: 0.95, green: 0.75, blue: 0.20)
        default: return Color(red: 0.92, green: 0.36, blue: 0.36)
        }
    }

    private func rowHelp(_ row: ProviderUsage) -> String {
        var parts: [String] = ["\(row.provider.displayName) weekly plan usage"]
        if let p = row.weeklyPercent {
            if row.isStale {
                parts = ["\(row.provider.displayName) last known: \(Int(p.rounded()))%"]
                if let sampledAt = row.sampledAt {
                    parts.append("sample age: \(ageString(since: sampledAt))")
                }
                parts.append("not live — re-open the provider CLI to refresh")
            } else {
                parts = ["\(row.provider.displayName) weekly: \(Int(p.rounded()))%"]
                if let resets = row.weeklyResetsAt {
                    parts.append("resets \(UsageMonitor.relativeReset(resets))")
                }
            }
        } else {
            switch row.placeholder {
            case "login": parts.append("sign in via the provider CLI")
            case "wait": parts.append("rate-limited; try again shortly")
            case "err": parts.append("couldn’t fetch")
            default:
                switch row.provider {
                case .grok:
                    parts.append("run Grok once so it logs billing credits")
                case .fable:
                    parts.append("no Fable weekly-scoped limit in Claude usage response")
                default:
                    parts.append("no data yet")
                }
            }
        }
        if row.shortWindowWarning && !row.isStale, let detail = row.shortWindowDetail {
            parts.append("⚠ \(detail)")
        }
        parts.append("Click to open usage page. Right-click to refresh.")
        return parts.joined(separator: "\n")
    }

    private func ageString(since date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds > 48 * 3600 ? [.day, .hour] : (seconds > 3600 ? [.hour, .minute] : [.minute])
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "…"
    }

    private var helpText: String {
        "Weekly AI plan usage (Claude · Fable · Codex · Grok). Dashed bar + %* = last known (>6h). Yellow triangle = 5-hour window nearly full."
    }
}
