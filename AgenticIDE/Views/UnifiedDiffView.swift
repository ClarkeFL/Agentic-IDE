import AppKit
import SwiftUI

/// Single-pane unified diff: HEAD vs working copy, lines tinted green for
/// additions, red for removals, transparent for unchanged context. Replaces
/// the old side-by-side `diffSplit` so a reader's eye doesn't have to
/// ping-pong between two panels — the change is highlighted in line.
///
/// Diff is computed in-process from `headText` vs the live `workingText` via
/// Swift's `CollectionDifference` (Myers diff) on `[String]` line arrays.
/// Both the diff and the syntax-highlighting pass run off-main and land in
/// `@State`, so scrolling never re-runs them. The lazy `LazyVStack` keeps
/// per-frame render cost bounded by the visible-row count.
struct UnifiedDiffView: View {
    let headText: String
    let workingText: String
    /// File extension (no leading dot) — used to pick a highlight.js grammar.
    /// Empty / unknown extensions skip the highlight pass and render plain.
    let fileExtension: String

    @State private var rows: [DiffRow] = []
    @State private var stats: Stats = .zero
    @State private var highlight: HighlightCache = .empty

    /// Single shared `SyntaxHighlighter` for all diff views. Highlightr's
    /// JSContext spin-up is ~30 ms — paying that once at first diff render
    /// is fine; paying it per view would tank pane switches.
    private static let highlighter = SyntaxHighlighter()

    /// Width of the line-number gutter, sized so a 5-digit file (≤99,999
    /// lines) doesn't visually shift as you scroll. Single column — we used
    /// to render old + new side-by-side, but for unchanged rows the two
    /// numbers are usually within a small offset and read as a doubled-up
    /// gutter. Switched to GitHub/VS-Code inline-diff convention: removed
    /// rows show the HEAD line number, added/unchanged rows show the
    /// working-copy number.
    private let gutterColumnWidth: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        DiffLineView(
                            row: row,
                            gutterWidth: gutterColumnWidth,
                            attributed: highlight.line(for: row)
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .task(id: InputKey(head: headText, work: workingText, ext: fileExtension)) {
            await rebuild()
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
            Text("+\(stats.added)")
                .font(DS.Font.stats)
                .foregroundStyle(DiffPalette.addText)
            Text("−\(stats.removed)")
                .font(DS.Font.stats)
                .foregroundStyle(DiffPalette.delText)
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Async rebuild

    /// Recompute the diff + highlight off-main, then publish the results.
    /// Triggered via `.task(id:)` so SwiftUI cancels any in-flight rebuild
    /// when the inputs change again before we finish.
    private func rebuild() async {
        let head = headText
        let work = workingText
        let ext = fileExtension
        let computed = await Task.detached(priority: .userInitiated) { () -> Computed in
            let rows = Self.computeRows(head: head, work: work)
            var added = 0
            var removed = 0
            for r in rows {
                switch r.kind {
                case .added: added += 1
                case .removed: removed += 1
                case .unchanged: break
                }
            }
            let highlight = Self.buildHighlight(head: head, work: work, ext: ext)
            return Computed(rows: rows, stats: Stats(added: added, removed: removed),
                            highlight: highlight)
        }.value
        if Task.isCancelled { return }
        self.rows = computed.rows
        self.stats = computed.stats
        self.highlight = computed.highlight
    }

    private struct Computed {
        let rows: [DiffRow]
        let stats: Stats
        let highlight: HighlightCache
    }

    // MARK: - Diff computation

    /// Build a flat row list aligning HEAD lines with working-copy lines.
    /// `CollectionDifference` gives us removals (offsets in HEAD) and
    /// insertions (offsets in working). Walking both indices in lockstep
    /// produces the unified output: removals at `i`, insertions at `j`,
    /// otherwise the lines match and we emit one unchanged row.
    nonisolated static func computeRows(head: String, work: String) -> [DiffRow] {
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

    nonisolated private static func trimTrailingEmpty(_ lines: [String]) -> [String] {
        guard let last = lines.last, last.isEmpty, lines.count > 1 else { return lines }
        return Array(lines.dropLast())
    }

    // MARK: - Highlight pre-pass

    /// Run highlight.js (via Highlightr) on both buffers and slice the
    /// results into per-line `AttributedString`s keyed by 1-based line
    /// number. Returns an empty cache if the extension is unknown or the
    /// file is over the highlighter's size cap — `DiffLineView` falls
    /// back to plain `Text(String)` in that case.
    nonisolated static func buildHighlight(head: String, work: String, ext: String) -> HighlightCache {
        guard let language = highlighter.languageName(forExtension: ext) else {
            return .empty
        }
        let workLines = highlighter.shouldHighlight(byteCount: work.utf8.count)
            ? sliceHighlight(text: work, language: language)
            : [:]
        let headLines = highlighter.shouldHighlight(byteCount: head.utf8.count)
            ? sliceHighlight(text: head, language: language)
            : [:]
        return HighlightCache(work: workLines, head: headLines)
    }

    /// Run the highlighter on the full buffer and split the result into a
    /// 1-indexed line-number → `AttributedString` map. The whole-file pass
    /// is cheap; per-line slicing is just NSString newline scanning.
    /// Strips Highlightr's `.font` attribute so the diff's own monospaced
    /// font (applied at the SwiftUI Text level) wins.
    nonisolated private static func sliceHighlight(text: String, language: String) -> [Int: AttributedString] {
        guard let attributed = highlighter.attributedHighlight(text: text, language: language) else {
            return [:]
        }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: mutable.length)
        // Drop everything except foregroundColor — font/background/etc would
        // otherwise override the SwiftUI styling we apply per row.
        mutable.enumerateAttributes(in: full) { attrs, range, _ in
            for key in attrs.keys where key != .foregroundColor {
                mutable.removeAttribute(key, range: range)
            }
        }

        var out: [Int: AttributedString] = [:]
        let raw = mutable.string as NSString
        let len = raw.length
        var lineIdx = 1
        var start = 0
        var i = 0
        while i < len {
            if raw.character(at: i) == 0x0A {
                let range = NSRange(location: start, length: i - start)
                out[lineIdx] = AttributedString(mutable.attributedSubstring(from: range))
                lineIdx += 1
                start = i + 1
            }
            i += 1
        }
        // Final line (after the last newline, or the whole buffer if there
        // are no newlines). Skip if it's a phantom trailing empty produced
        // by a file that ends in "\n" — `computeRows` trims that too, so
        // including it here would create an off-by-one on the last row.
        if start < len {
            let range = NSRange(location: start, length: len - start)
            out[lineIdx] = AttributedString(mutable.attributedSubstring(from: range))
        }
        return out
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

// MARK: - Caches & keys

/// Per-line attributed text for both sides of the diff, looked up by row
/// kind. Stored in `@State` so scroll-driven body re-evals reuse the same
/// dictionary without re-running highlight.js.
struct HighlightCache {
    let work: [Int: AttributedString]
    let head: [Int: AttributedString]

    static let empty = HighlightCache(work: [:], head: [:])

    func line(for row: DiffRow) -> AttributedString? {
        switch row.kind {
        case .removed: return row.oldLine.flatMap { head[$0] }
        case .added, .unchanged: return row.newLine.flatMap { work[$0] }
        }
    }
}

private struct Stats: Equatable {
    let added: Int
    let removed: Int
    static let zero = Stats(added: 0, removed: 0)
}

/// Composite key for `task(id:)` — re-runs the diff/highlight only when one
/// of the inputs actually changes. String equality hits the COW fast path
/// when the underlying buffer hasn't been swapped, so per-body checks are
/// O(1) in the steady-state-no-edit case (which is what scroll triggers).
private struct InputKey: Hashable {
    let head: String
    let work: String
    let ext: String
}

// MARK: - Row rendering

private struct DiffLineView: View {
    let row: DiffRow
    let gutterWidth: CGFloat
    /// Pre-highlighted line text. `nil` for unknown extensions / oversized
    /// files / lines outside the cache — we fall back to plain rendering.
    let attributed: AttributedString?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // Single line-number gutter. For removed rows we show the HEAD
            // line; for added/unchanged we show the working-copy line. The
            // sign column adjacent disambiguates.
            gutterText(displayedLineNumber)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 4)
            // Sign column.
            Text(signGlyph)
                .font(DS.Font.codeBody)
                .foregroundStyle(signColor)
                .frame(width: 14, alignment: .center)
            // Line content. Use the highlighted slice when available; fall
            // back to the plain row text otherwise.
            content
                .font(DS.Font.codeBody)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 1)
        .background(rowBackground)
    }

    @ViewBuilder
    private var content: some View {
        if let attributed {
            // Removed rows are tinted red as a whole; pushing the syntax
            // colours through would fight the row's "this line is gone"
            // signal. Added/unchanged rows show full syntax colours.
            switch row.kind {
            case .removed:
                Text(row.text.isEmpty ? " " : row.text)
                    .foregroundStyle(DiffPalette.delText)
            case .added, .unchanged:
                Text(attributed)
            }
        } else {
            Text(row.text.isEmpty ? " " : row.text)
                .foregroundStyle(textColor)
        }
    }

    private var displayedLineNumber: Int? {
        switch row.kind {
        case .removed: return row.oldLine
        case .added, .unchanged: return row.newLine
        }
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
