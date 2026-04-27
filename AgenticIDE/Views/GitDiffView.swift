import SwiftUI

/// Renders a unified diff (the raw text from `git diff --no-color`) with
/// the layout the rest of the industry has converged on: a file header
/// bar at the top showing the path / status / +-/+ counts, then dual line-
/// number gutters next to each line, hunk separators rendered as a colored
/// band with the function context, and add/remove rows tinted in their
/// own row color. Meta header lines (`diff --git`, `index`, `--- a/...`,
/// `+++ b/...`) are stripped — they're noise once we have the file bar.
struct GitDiffView: View {
    let diffText: String
    let isLoading: Bool
    let placeholder: String
    let header: DiffHeader?

    var body: some View {
        Group {
            if isLoading {
                loadingState
            } else if diffText.isEmpty {
                emptyState
            } else {
                contentView
            }
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Loading diff…")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(placeholder)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    @ViewBuilder
    private var contentView: some View {
        let parsed = DiffParser.parse(diffText)
        VStack(spacing: 0) {
            if let header {
                DiffFileHeader(header: header, stats: parsed.stats)
                Divider()
            }
            // GeometryReader gives each row a `minLineWidth` so short rows
            // (and their colored backgrounds) stretch across the viewport
            // while long rows extend past it and trigger horizontal scroll.
            // The explicit maxHeight: .infinity is critical — without it,
            // GeometryReader collapses to zero height inside a VStack and
            // the ScrollView gets no viewport to scroll within.
            // Single ScrollView with both axes + eager VStack so the content
            // reports its real maximum width up front. LazyVStack measures
            // only currently-rendered rows, which kept the content reported
            // as ≈ viewport width — no horizontal overflow → no h-scroll.
            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(parsed.rows) { row in
                        DiffRowView(row: row)
                    }
                }
                .padding(.vertical, 2)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        }
    }
}

// MARK: - Header bar

struct DiffHeader: Equatable {
    let displayName: String
    let directory: String
    let status: GitFileStatus
    let stateSubtitle: String
}

private struct DiffFileHeader: View {
    let header: DiffHeader
    let stats: DiffStats

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                // Filename is the primary signal — pin it to the leading
                // edge with high layout priority so the path beside/below
                // takes the truncation hit instead of the filename.
                Text(header.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                // Path + status on one secondary line, separated by `·`.
                // Path truncates from the head when narrow ("…tic-IDE/Views").
                HStack(spacing: 6) {
                    if !header.directory.isEmpty {
                        Text(header.directory)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text("·")
                            .foregroundStyle(.tertiary)
                    }
                    Text(header.stateSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .font(.system(size: 10, weight: .medium))
            }
            Spacer(minLength: 12)
            statsBar
        }
        .padding(.leading, 14)
        .padding(.trailing, 22)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var statsBar: some View {
        HStack(spacing: 6) {
            Text("+\(stats.additions)")
                .foregroundStyle(Color(red: 0.22, green: 0.78, blue: 0.45))
            Text("-\(stats.deletions)")
                .foregroundStyle(Color(red: 0.90, green: 0.30, blue: 0.30))
        }
        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
    }
}

// MARK: - Row view

private struct DiffRowView: View {
    let row: DiffRow

    private static let gutterWidth: CGFloat = 30
    private static let monoFont: Font = .system(size: 11.5, design: .monospaced)
    private static let gutterFont: Font = .system(size: 10, weight: .medium, design: .monospaced)

    var body: some View {
        switch row.kind {
        case .hunk:
            hunkRow
        case .noNewline:
            noNewlineRow
        default:
            contentRow
        }
    }

    private var contentRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            gutter(row.oldLine)
            gutter(row.newLine)
            Text(signCharacter)
                .font(Self.monoFont)
                .foregroundStyle(signColor)
                .frame(width: 14, alignment: .center)
            Text(row.text.isEmpty ? " " : row.text)
                .font(Self.monoFont)
                .foregroundStyle(.primary)
                .padding(.trailing, 12)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.vertical, 0.5)
        .background(rowBackground)
        .textSelection(.enabled)
    }

    private var hunkRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("⋯")
                .font(Self.gutterFont)
                .foregroundStyle(.tertiary)
                .frame(width: Self.gutterWidth, alignment: .trailing)
                .padding(.trailing, 6)
            Text("⋯")
                .font(Self.gutterFont)
                .foregroundStyle(.tertiary)
                .frame(width: Self.gutterWidth, alignment: .trailing)
                .padding(.trailing, 6)
            Text(row.text.isEmpty ? "—" : row.text)
                .font(Self.monoFont.italic())
                .foregroundStyle(Color(red: 0.55, green: 0.45, blue: 0.95))
                .padding(.leading, 6)
                .padding(.trailing, 12)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.vertical, 2)
        .background(Color(red: 0.55, green: 0.45, blue: 0.95).opacity(0.10))
    }

    private var noNewlineRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            blankGutter
            blankGutter
            Text(row.text)
                .font(Self.monoFont.italic())
                .foregroundStyle(.tertiary)
                .padding(.leading, 6)
                .padding(.trailing, 12)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.vertical, 0.5)
    }

    private func gutter(_ lineNo: Int?) -> some View {
        Text(lineNo.map(String.init) ?? "")
            .font(Self.gutterFont)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .frame(width: Self.gutterWidth, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var blankGutter: some View {
        Text("")
            .frame(width: Self.gutterWidth, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var signCharacter: String {
        switch row.kind {
        case .add: return "+"
        case .remove: return "−"
        case .context: return " "
        default: return " "
        }
    }

    private var signColor: Color {
        switch row.kind {
        case .add: return Color(red: 0.22, green: 0.78, blue: 0.45)
        case .remove: return Color(red: 0.90, green: 0.30, blue: 0.30)
        default: return .secondary
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        switch row.kind {
        case .add: Color(red: 0.22, green: 0.78, blue: 0.45).opacity(0.12)
        case .remove: Color(red: 0.90, green: 0.30, blue: 0.30).opacity(0.12)
        default: Color.clear
        }
    }
}

// MARK: - Parser

struct DiffRow: Identifiable, Hashable {
    enum Kind { case context, add, remove, hunk, noNewline }

    let id: Int
    let kind: Kind
    let oldLine: Int?
    let newLine: Int?
    let text: String
}

struct DiffStats: Equatable {
    var additions: Int = 0
    var deletions: Int = 0
}

enum DiffParser {
    /// Parses unified-diff text into structured rows + summary stats.
    /// Drops the meta header lines that `git diff` emits before the first
    /// hunk (`diff --git`, `index ...`, `--- a/...`, `+++ b/...`, etc.) —
    /// the file-header bar shows that information already.
    static func parse(_ raw: String) -> (rows: [DiffRow], stats: DiffStats) {
        var rows: [DiffRow] = []
        var stats = DiffStats()
        var rowId = 0
        var oldLine = 0
        var newLine = 0
        var sawFirstHunk = false

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if line.hasPrefix("@@") {
                let parsed = parseHunkHeader(line)
                oldLine = parsed.oldStart
                newLine = parsed.newStart
                rows.append(DiffRow(id: rowId, kind: .hunk,
                                    oldLine: nil, newLine: nil,
                                    text: parsed.context))
                rowId += 1
                sawFirstHunk = true
                continue
            }

            // Meta headers before the first hunk: drop them.
            if !sawFirstHunk {
                if isMetaHeader(line) || line.isEmpty { continue }
            }

            if line.hasPrefix("\\") {
                rows.append(DiffRow(id: rowId, kind: .noNewline,
                                    oldLine: nil, newLine: nil,
                                    text: line))
                rowId += 1
                continue
            }
            if line.hasPrefix("+") {
                let body = String(line.dropFirst())
                rows.append(DiffRow(id: rowId, kind: .add,
                                    oldLine: nil, newLine: newLine,
                                    text: body))
                rowId += 1
                newLine += 1
                stats.additions += 1
                continue
            }
            if line.hasPrefix("-") {
                let body = String(line.dropFirst())
                rows.append(DiffRow(id: rowId, kind: .remove,
                                    oldLine: oldLine, newLine: nil,
                                    text: body))
                rowId += 1
                oldLine += 1
                stats.deletions += 1
                continue
            }
            if line.hasPrefix(" ") {
                let body = String(line.dropFirst())
                rows.append(DiffRow(id: rowId, kind: .context,
                                    oldLine: oldLine, newLine: newLine,
                                    text: body))
                rowId += 1
                oldLine += 1
                newLine += 1
                continue
            }
            // Blank or stray line inside the hunk region — render as
            // empty context so layout doesn't jump.
            if line.isEmpty {
                rows.append(DiffRow(id: rowId, kind: .context,
                                    oldLine: oldLine, newLine: newLine,
                                    text: ""))
                rowId += 1
                oldLine += 1
                newLine += 1
            }
        }
        return (rows, stats)
    }

    private static func isMetaHeader(_ line: String) -> Bool {
        line.hasPrefix("diff ")
            || line.hasPrefix("index ")
            || line.hasPrefix("--- ")
            || line.hasPrefix("+++ ")
            || line.hasPrefix("new file")
            || line.hasPrefix("deleted file")
            || line.hasPrefix("similarity ")
            || line.hasPrefix("rename ")
            || line.hasPrefix("copy ")
            || line.hasPrefix("Binary files")
    }

    /// Parses `@@ -<a>[,<b>] +<c>[,<d>] @@ <context>` into starts + the
    /// trailing context (function name, etc.). Returns zeros if the line
    /// doesn't match (defensive — git always emits valid hunk headers).
    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int, context: String) {
        let pattern = #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (0, 0, line)
        }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: nsRange),
              match.numberOfRanges >= 4 else {
            return (0, 0, line)
        }
        let nsLine = line as NSString
        let old = Int(nsLine.substring(with: match.range(at: 1))) ?? 0
        let new = Int(nsLine.substring(with: match.range(at: 2))) ?? 0
        let ctx = nsLine.substring(with: match.range(at: 3))
            .trimmingCharacters(in: .whitespaces)
        return (old, new, ctx)
    }
}
