import AppKit

/// Purpose-built Markdown colouriser for the source editor. Highlight.js's
/// `markdown` grammar only really paints headings, so long docs read as a
/// grey wall. This walks the text with a small set of regexes and assigns
/// high-contrast roles (heading / code / link / list / quote / emphasis)
/// so structure is obvious at a glance while editing.
///
/// Pure and thread-safe: no UI access. The editor only copies the
/// `.foregroundColor` ranges onto its `NSTextStorage`.
enum MarkdownSyntaxHighlight {

    static func attributedString(for text: String) -> NSAttributedString {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let out = NSMutableAttributedString(string: text)
        let palette = Palette.current

        out.addAttribute(.foregroundColor, value: palette.body, range: full)

        // Fenced code first so later rules can skip those ranges.
        var fenceRanges: [NSRange] = []
        apply(pattern: #"^```[^\n]*\n[\s\S]*?^```"#,
              options: [.anchorsMatchLines],
              in: ns, full: full) { range, _ in
            fenceRanges.append(range)
            out.addAttribute(.foregroundColor, value: palette.codeBlock, range: range)
            // Colour the opening/closing fence lines a touch brighter.
            colorFenceMarkers(in: ns, range: range, onto: out, color: palette.codeFence)
        }

        // Headings: whole line including the # markers.
        apply(pattern: #"^#{1,6}[ \t]+.+$"#,
              options: [.anchorsMatchLines],
              in: ns, full: full, skipping: fenceRanges) { range, _ in
            out.addAttribute(.foregroundColor, value: palette.heading, range: range)
            // Soften the leading ### so the title text pops more.
            let hashes = ns.range(of: #"^#{1,6}"#, options: .regularExpression, range: range)
            if hashes.location != NSNotFound {
                out.addAttribute(.foregroundColor, value: palette.headingMarker, range: hashes)
            }
        }

        // Blockquotes.
        apply(pattern: #"^>[ \t]?.*$"#,
              options: [.anchorsMatchLines],
              in: ns, full: full, skipping: fenceRanges) { range, _ in
            out.addAttribute(.foregroundColor, value: palette.blockquote, range: range)
        }

        // Horizontal rules.
        apply(pattern: #"^([-*_])(?:\s*\1){2,}\s*$"#,
              options: [.anchorsMatchLines],
              in: ns, full: full, skipping: fenceRanges) { range, _ in
            out.addAttribute(.foregroundColor, value: palette.rule, range: range)
        }

        // List markers (unordered + ordered) — just the bullet / number.
        apply(pattern: #"^[ \t]*([-*+]|\d+\.)[ \t]+"#,
              options: [.anchorsMatchLines],
              in: ns, full: full, skipping: fenceRanges) { range, _ in
            out.addAttribute(.foregroundColor, value: palette.listMarker, range: range)
        }

        // Task-list checkboxes: - [ ] / - [x]
        apply(pattern: #"^[ \t]*[-*+][ \t]+\[[ xX]\]"#,
              options: [.anchorsMatchLines],
              in: ns, full: full, skipping: fenceRanges) { range, _ in
            out.addAttribute(.foregroundColor, value: palette.listMarker, range: range)
        }

        // Inline code `like this` (not fences).
        apply(pattern: #"`[^`\n]+`"#,
              options: [],
              in: ns, full: full, skipping: fenceRanges) { range, _ in
            out.addAttribute(.foregroundColor, value: palette.inlineCode, range: range)
        }

        // Links [label](url) and images ![alt](url).
        apply(pattern: #"!?\[([^\]]*)\]\(([^)]+)\)"#,
              options: [],
              in: ns, full: full, skipping: fenceRanges) { range, match in
            out.addAttribute(.foregroundColor, value: palette.linkLabel, range: range)
            if match.numberOfRanges > 2 {
                let urlRange = match.range(at: 2)
                if urlRange.location != NSNotFound {
                    out.addAttribute(.foregroundColor, value: palette.linkURL, range: urlRange)
                }
            }
        }

        // Autolinks <https://...> and bare angle refs.
        apply(pattern: #"<(https?://[^>\s]+)>"#,
              options: [],
              in: ns, full: full, skipping: fenceRanges) { range, _ in
            out.addAttribute(.foregroundColor, value: palette.linkURL, range: range)
        }

        // Bold **text** / __text__ (before italic so *** works reasonably).
        apply(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#,
              options: [],
              in: ns, full: full, skipping: fenceRanges) { range, _ in
            out.addAttribute(.foregroundColor, value: palette.bold, range: range)
        }

        // Italic *text* / _text_ — avoid matching list bullets by requiring
        // non-space after the opener and a non-space before the closer.
        apply(pattern: #"(?<!\*)\*(?!\*)(?=\S)(.+?)(?<=\S)\*(?!\*)|(?<!_)_(?!_)(?=\S)(.+?)(?<=\S)_(?!_)"#,
              options: [],
              in: ns, full: full, skipping: fenceRanges) { range, _ in
            out.addAttribute(.foregroundColor, value: palette.italic, range: range)
        }

        // Strikethrough ~~text~~.
        apply(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#,
              options: [],
              in: ns, full: full, skipping: fenceRanges) { range, _ in
            out.addAttribute(.foregroundColor, value: palette.strike, range: range)
        }

        // HTML tags that sometimes appear in MD docs.
        apply(pattern: #"</?[A-Za-z][A-Za-z0-9-]*(?:\s[^>]*)?>"#,
              options: [],
              in: ns, full: full, skipping: fenceRanges) { range, _ in
            out.addAttribute(.foregroundColor, value: palette.html, range: range)
        }

        return out
    }

    // MARK: - Helpers

    private static func apply(pattern: String,
                              options: NSRegularExpression.Options,
                              in ns: NSString,
                              full: NSRange,
                              skipping: [NSRange] = [],
                              body: (NSRange, NSTextCheckingResult) -> Void) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return
        }
        regex.enumerateMatches(in: ns as String, options: [], range: full) { match, _, _ in
            guard let match else { return }
            let range = match.range
            guard range.location != NSNotFound, range.length > 0 else { return }
            if skipping.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                return
            }
            body(range, match)
        }
    }

    private static func colorFenceMarkers(in ns: NSString,
                                          range: NSRange,
                                          onto out: NSMutableAttributedString,
                                          color: NSColor) {
        // Opening ```lang line and closing ``` line.
        let sub = ns.substring(with: range) as NSString
        var search = NSRange(location: 0, length: sub.length)
        // First line
        let firstBreak = sub.range(of: "\n", options: [], range: search)
        if firstBreak.location != NSNotFound {
            let open = NSRange(location: range.location, length: firstBreak.location)
            out.addAttribute(.foregroundColor, value: color, range: open)
        }
        // Last line starting at the final ```
        if let closeRegex = try? NSRegularExpression(pattern: #"```[ \t]*$"#, options: [.anchorsMatchLines]) {
            let localFull = NSRange(location: 0, length: sub.length)
            if let last = closeRegex.matches(in: sub as String, options: [], range: localFull).last {
                let abs = NSRange(location: range.location + last.range.location,
                                  length: last.range.length)
                out.addAttribute(.foregroundColor, value: color, range: abs)
            }
        }
    }

    // MARK: - Palette

    private struct Palette {
        let body: NSColor
        let heading: NSColor
        let headingMarker: NSColor
        let bold: NSColor
        let italic: NSColor
        let inlineCode: NSColor
        let codeBlock: NSColor
        let codeFence: NSColor
        let linkLabel: NSColor
        let linkURL: NSColor
        let listMarker: NSColor
        let blockquote: NSColor
        let rule: NSColor
        let strike: NSColor
        let html: NSColor

        static var current: Palette {
            let dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? .dark : .light
        }

        /// Tuned for dark chrome (atom-one-dark adjacent, but more roles).
        static let dark = Palette(
            body: NSColor(srgbRed: 0.72, green: 0.75, blue: 0.80, alpha: 1),
            heading: NSColor(srgbRed: 0.97, green: 0.46, blue: 0.50, alpha: 1),       // coral
            headingMarker: NSColor(srgbRed: 0.97, green: 0.46, blue: 0.50, alpha: 0.55),
            bold: NSColor(srgbRed: 0.97, green: 0.90, blue: 0.72, alpha: 1),           // warm cream
            italic: NSColor(srgbRed: 0.78, green: 0.63, blue: 0.95, alpha: 1),         // soft purple
            inlineCode: NSColor(srgbRed: 0.60, green: 0.86, blue: 0.62, alpha: 1),     // green
            codeBlock: NSColor(srgbRed: 0.55, green: 0.78, blue: 0.58, alpha: 0.95),
            codeFence: NSColor(srgbRed: 0.45, green: 0.55, blue: 0.50, alpha: 1),
            linkLabel: NSColor(srgbRed: 0.45, green: 0.70, blue: 0.98, alpha: 1),      // blue
            linkURL: NSColor(srgbRed: 0.40, green: 0.78, blue: 0.88, alpha: 1),        // cyan
            listMarker: NSColor(srgbRed: 0.90, green: 0.65, blue: 0.35, alpha: 1),     // amber
            blockquote: NSColor(srgbRed: 0.55, green: 0.68, blue: 0.55, alpha: 1),     // muted green
            rule: NSColor(srgbRed: 0.45, green: 0.48, blue: 0.55, alpha: 1),
            strike: NSColor(srgbRed: 0.55, green: 0.55, blue: 0.60, alpha: 1),
            html: NSColor(srgbRed: 0.85, green: 0.55, blue: 0.70, alpha: 1)
        )

        static let light = Palette(
            body: NSColor(srgbRed: 0.22, green: 0.24, blue: 0.28, alpha: 1),
            heading: NSColor(srgbRed: 0.78, green: 0.18, blue: 0.25, alpha: 1),
            headingMarker: NSColor(srgbRed: 0.78, green: 0.18, blue: 0.25, alpha: 0.50),
            bold: NSColor(srgbRed: 0.45, green: 0.28, blue: 0.05, alpha: 1),
            italic: NSColor(srgbRed: 0.42, green: 0.22, blue: 0.65, alpha: 1),
            inlineCode: NSColor(srgbRed: 0.10, green: 0.48, blue: 0.22, alpha: 1),
            codeBlock: NSColor(srgbRed: 0.12, green: 0.42, blue: 0.24, alpha: 1),
            codeFence: NSColor(srgbRed: 0.40, green: 0.48, blue: 0.42, alpha: 1),
            linkLabel: NSColor(srgbRed: 0.12, green: 0.35, blue: 0.78, alpha: 1),
            linkURL: NSColor(srgbRed: 0.05, green: 0.48, blue: 0.62, alpha: 1),
            listMarker: NSColor(srgbRed: 0.72, green: 0.40, blue: 0.05, alpha: 1),
            blockquote: NSColor(srgbRed: 0.28, green: 0.45, blue: 0.30, alpha: 1),
            rule: NSColor(srgbRed: 0.55, green: 0.58, blue: 0.62, alpha: 1),
            strike: NSColor(srgbRed: 0.50, green: 0.50, blue: 0.55, alpha: 1),
            html: NSColor(srgbRed: 0.65, green: 0.22, blue: 0.42, alpha: 1)
        )
    }
}
