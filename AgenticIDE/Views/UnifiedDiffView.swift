import SwiftUI

/// Single-pane unified diff: HEAD on the left as line numbers + working
/// copy on the right as line numbers, lines tinted green for additions,
/// red for removals, transparent for unchanged context. Replaces the old
/// side-by-side `diffSplit` so a reader's eye doesn't have to ping-pong
/// between two panels — the change is highlighted in line.
///
/// Diff is computed in-process from `headText` vs the live `tab.text`, so
/// it updates as the user types. We use Swift's built-in
/// `CollectionDifference` (Myers diff) on `[String]` line arrays — fine
/// for normal source files, and the lazy `LazyVStack` keeps render cost
/// bounded by the visible-row count.
struct UnifiedDiffView: View {
    let headText: String
    let workingText: String

    private var rows: [DiffRow] { Self.computeRows(head: headText, work: workingText) }
    private var stats: (added: Int, removed: Int) {
        var a = 0, r = 0
        for row in rows {
            switch row.kind {
            case .added: a += 1
            case .removed: r += 1
            case .unchanged: break
            }
        }
        return (a, r)
    }

    /// Width of the line-number gutter, sized so a 5-digit file (≤99,999
    /// lines) doesn't visually shift as you scroll. Two sub-columns each
    /// `gutterDigitWidth × 5` wide for the old/new line numbers.
    private let gutterDigitWidth: CGFloat = 7.5
    private var gutterColumnWidth: CGFloat { gutterDigitWidth * 5 + 8 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        DiffLineView(row: row, gutterWidth: gutterColumnWidth)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    /// Strip across the top: short title, plus a +N −N stat readout in
    /// monospaced digits so the user can confirm at a glance "yes, this is
    /// the right diff".
    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Unified diff")
                .font(DS.Font.control)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            let s = stats
            Text("+\(s.added)")
                .font(DS.Font.stats)
                .foregroundStyle(DiffPalette.addText)
            Text("−\(s.removed)")
                .font(DS.Font.stats)
                .foregroundStyle(DiffPalette.delText)
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Diff computation

    /// Build a flat row list aligning HEAD lines with working-copy lines.
    /// `CollectionDifference` gives us removals (offsets in HEAD) and
    /// insertions (offsets in working). Walking both indices in lockstep
    /// produces the unified output: removals at `i`, insertions at `j`,
    /// otherwise the lines match and we emit one unchanged row.
    static func computeRows(head: String, work: String) -> [DiffRow] {
        let oldLines = head.components(separatedBy: "\n")
        let newLines = work.components(separatedBy: "\n")

        // Trim a single trailing empty line that `components(separatedBy:)`
        // produces for files that end with "\n" — otherwise both sides
        // appear to have a phantom blank last row that always matches.
        let old = trimTrailingEmpty(oldLines)
        let new = trimTrailingEmpty(newLines)

        let diff = new.difference(from: old)
        var removals: [Int: String] = [:]
        var insertions: [Int: String] = [:]
        for change in diff {
            switch change {
            case .remove(let offset, let element, _): removals[offset] = element
            case .insert(let offset, let element, _): insertions[offset] = element
            }
        }

        var rows: [DiffRow] = []
        var i = 0  // index into old
        var j = 0  // index into new
        var nextId = 0
        while i < old.count || j < new.count {
            // Process all removals at the current `i` first — they're
            // anchored to the old collection's offset.
            while let line = removals[i] {
                rows.append(DiffRow(id: nextId, kind: .removed,
                                    oldLine: i + 1, newLine: nil, text: line))
                nextId += 1
                i += 1
            }
            // Then all insertions at the current `j` (offset in new).
            while let line = insertions[j] {
                rows.append(DiffRow(id: nextId, kind: .added,
                                    oldLine: nil, newLine: j + 1, text: line))
                nextId += 1
                j += 1
            }
            // Anything remaining at i,j must be a common (unchanged) line.
            if i < old.count && j < new.count {
                rows.append(DiffRow(id: nextId, kind: .unchanged,
                                    oldLine: i + 1, newLine: j + 1, text: old[i]))
                nextId += 1
                i += 1
                j += 1
            } else {
                break
            }
        }
        return rows
    }

    private static func trimTrailingEmpty(_ lines: [String]) -> [String] {
        guard let last = lines.last, last.isEmpty, lines.count > 1 else { return lines }
        return Array(lines.dropLast())
    }
}

/// One row in the diff. `oldLine`/`newLine` are 1-indexed for display.
/// nil-out the side that doesn't exist (added rows have no old line; removed
/// rows have no new line).
struct DiffRow: Identifiable, Equatable {
    let id: Int
    enum Kind { case unchanged, added, removed }
    let kind: Kind
    let oldLine: Int?
    let newLine: Int?
    let text: String
}

// MARK: - Row rendering

private struct DiffLineView: View {
    let row: DiffRow
    let gutterWidth: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // Old-line gutter.
            gutterText(row.oldLine)
                .frame(width: gutterWidth, alignment: .trailing)
            // New-line gutter.
            gutterText(row.newLine)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 4)
            // Sign column.
            Text(signGlyph)
                .font(DS.Font.codeBody)
                .foregroundStyle(signColor)
                .frame(width: 14, alignment: .center)
            // Line content.
            Text(row.text.isEmpty ? " " : row.text)
                .font(DS.Font.codeBody)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 1)
        .background(rowBackground)
    }

    private var signGlyph: String {
        switch row.kind {
        case .added: return "+"
        case .removed: return "−"
        case .unchanged: return " "
        }
    }

    private var signColor: Color {
        switch row.kind {
        case .added: return DiffPalette.addText
        case .removed: return DiffPalette.delText
        case .unchanged: return .secondary
        }
    }

    private var textColor: Color {
        switch row.kind {
        case .added: return DiffPalette.addText
        case .removed: return DiffPalette.delText
        case .unchanged: return .primary
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        switch row.kind {
        case .added: DiffPalette.addBg
        case .removed: DiffPalette.delBg
        case .unchanged: Color.clear
        }
    }

    private func gutterText(_ n: Int?) -> some View {
        Text(n.map { String($0) } ?? "")
            .font(.system(size: DS.FontSize.caption,
                          weight: .regular,
                          design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
    }
}

/// Diff colour palette. Tuned so the green/red are clearly distinct on
/// dark mode without overwhelming the unchanged context lines.
enum DiffPalette {
    static let addBg = Color(red: 0.18, green: 0.55, blue: 0.32).opacity(0.18)
    static let delBg = Color(red: 0.78, green: 0.25, blue: 0.25).opacity(0.18)
    static let addText = Color(red: 0.48, green: 0.85, blue: 0.55)
    static let delText = Color(red: 0.95, green: 0.55, blue: 0.55)
}
