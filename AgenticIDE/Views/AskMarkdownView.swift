import AppKit
import SwiftUI

/// Lightweight markdown renderer for Ask chat turns. We don't pull in a full
/// markdown engine — the model's output is mostly prose with the occasional
/// fenced code block, headings, and lists. This splits the text into block
/// elements and renders each natively: paragraphs keep inline `**bold**` /
/// `*italic*` / `code` / links via `AttributedString`, while fenced code blocks
/// get their own monospace card with a Copy button (the headline feature).
///
/// Streaming-safe: an unterminated ``` fence renders as an in-progress code
/// block instead of swallowing the rest of the message.
struct AskMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            ForEach(AskBlock.parse(text)) { block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: AskBlock) -> some View {
        switch block.kind {
        case let .paragraph(text):
            Self.inline(text)
                .font(.system(size: DS.FontSize.body + 1))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case let .heading(level, text):
            Self.inline(text)
                .font(.system(size: headingSize(level), weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.xs)

        case let .listItem(indent, marker, text):
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                Text(marker)
                    .font(.system(size: DS.FontSize.body + 1))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Self.inline(text)
                    .font(.system(size: DS.FontSize.body + 1))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * DS.Space.lg)

        case let .quote(text):
            HStack(spacing: DS.Space.md) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Self.inline(text)
                    .font(.system(size: DS.FontSize.body + 1))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case let .code(language, code):
            CodeBlockView(language: language, code: code)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return DS.FontSize.body + 7   // 19
        case 2: return DS.FontSize.body + 4   // 16
        default: return DS.FontSize.body + 2  // 14
        }
    }

    /// Inline markdown only: keeps newlines, renders `**bold**` / `*italic*` /
    /// `` `code` `` / links. Falls back to plain text if parsing throws.
    static func inline(_ string: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attr = try? AttributedString(markdown: string, options: options) {
            return Text(attr)
        }
        return Text(string)
    }
}

// MARK: - Block model + parser

struct AskBlock: Identifiable {
    enum Kind {
        case paragraph(String)
        case heading(level: Int, text: String)
        case listItem(indent: Int, marker: String, text: String)
        case quote(String)
        case code(language: String?, code: String)
    }

    let id: Int
    let kind: Kind

    /// Split markdown text into a flat list of block elements. Deliberately
    /// simple — line-oriented, one pass, no nesting beyond list indentation.
    static func parse(_ text: String) -> [AskBlock] {
        var blocks: [AskBlock] = []
        var paragraph: [String] = []
        var inCode = false
        var codeLanguage: String?
        var codeLines: [String] = []
        var counter = 0

        func emit(_ kind: Kind) {
            blocks.append(AskBlock(id: counter, kind: kind))
            counter += 1
        }
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            emit(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    emit(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
                    inCode = false; codeLanguage = nil; codeLines.removeAll()
                } else {
                    flushParagraph()
                    inCode = true
                    let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = lang.isEmpty ? nil : lang
                }
                continue
            }
            if inCode { codeLines.append(line); continue }

            if trimmed.isEmpty { flushParagraph(); continue }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                emit(.heading(level: heading.level, text: heading.text))
                continue
            }
            if let item = parseListItem(line) {
                flushParagraph()
                emit(.listItem(indent: item.indent, marker: item.marker, text: item.text))
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                emit(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }

            paragraph.append(line)
        }

        // Unterminated fence (still streaming) → render what we have so far.
        if inCode { emit(.code(language: codeLanguage, code: codeLines.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        var rest = Substring(trimmed)
        while rest.first == "#" && level < 6 { level += 1; rest = rest.dropFirst() }
        guard rest.first == " " else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func parseListItem(_ line: String) -> (indent: Int, marker: String, text: String)? {
        let leadingSpaces = line.prefix { $0 == " " }.count
        let indent = min(leadingSpaces / 2, 3)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Unordered: -, *, + followed by a space.
        if let first = trimmed.first, "-*+".contains(first),
           trimmed.dropFirst().first == " " {
            return (indent, "•", trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        // Ordered: "1." / "12)" followed by a space.
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty {
            let afterDigits = trimmed.dropFirst(digits.count)
            if let sep = afterDigits.first, sep == "." || sep == ")",
               afterDigits.dropFirst().first == " " {
                return (indent, "\(digits).", afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}

// MARK: - Code block

/// Monospace card for a fenced code block. Header strip shows the language and
/// a Copy button; the body scrolls horizontally so long lines don't wrap or
/// stretch the chat column.
struct CodeBlockView: View {
    let language: String?
    let code: String

    private var trimmedCode: String {
        code.trimmingCharacters(in: CharacterSet.newlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "code").uppercased())
                    .font(.system(size: DS.FontSize.micro, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: trimmedCode, label: "Copy")
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.xs)
            .background(Color.primary.opacity(0.05))

            Divider().opacity(0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(trimmedCode)
                    .font(DS.Font.codeBody)
                    .textSelection(.enabled)
                    .padding(DS.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
    }
}

// MARK: - Copy button

/// Reusable copy-to-clipboard control with a transient "Copied" confirmation.
/// `label == nil` renders icon-only (used for the per-message hover button).
struct CopyButton: View {
    let text: String
    var label: String?
    @State private var copied = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.2)) { copied = false }
            }
        } label: {
            HStack(spacing: DS.Space.xxs) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: DS.FontSize.footnote, weight: .medium))
                if let label {
                    Text(copied ? "Copied" : label)
                        .font(DS.Font.control)
                }
            }
            .foregroundStyle(copied ? Color.green : Color.secondary)
            .padding(.horizontal, label == nil ? DS.Space.xs : DS.Space.sm)
            .padding(.vertical, DS.Space.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy")
    }
}
