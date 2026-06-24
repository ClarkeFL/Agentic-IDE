import AppKit
import Highlightr

/// Wraps Highlightr (highlight.js via JavaScriptCore) and applies its
/// per-token foreground colours to an `NSTextStorage` in place. We never
/// replace the storage's string — only the colour attribute — so the
/// caller's cursor and selection survive every re-highlight.
///
/// One instance per `CodeEditor`. Highlightr's underlying JSContext is
/// expensive to spin up (~30 ms cold) but is reused across calls; we run
/// the highlight off main and only touch the storage on main.
final class SyntaxHighlighter {
    /// Highlightr wraps a JavaScriptCore context. Keep all access to that
    /// context serialized; racing calls can intermittently produce plain
    /// output for otherwise-supported grammars.
    private let renderQueue = DispatchQueue(label: "com.fabio.AgenticIDE.SyntaxHighlighter.render")
    private var highlightr: Highlightr?
    /// Files larger than this skip highlighting entirely. The JSContext
    /// is ~quadratic on some grammars and a 5MB minified JS file pinned
    /// the main thread for several seconds in early testing.
    private static let maxBytesToHighlight: Int = 512 * 1024

    init(theme: String = SyntaxHighlighter.defaultTheme()) {
        renderQueue.sync {
            let h = Highlightr()
            h?.ignoreIllegals = true
            _ = h?.setTheme(to: theme)
            self.highlightr = h
        }
    }

    /// System-aware default theme. Switches between a clean dark theme
    /// (atom-one-dark) and its light counterpart based on the current
    /// effective appearance.
    static func defaultTheme() -> String {
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? "atom-one-dark" : "atom-one-light"
    }

    /// Map a full file URL to a highlight.js language name. Some common
    /// developer files are named by convention rather than extension
    /// (`.env.local`, `Dockerfile`, `Makefile`), so check the filename before
    /// falling back to the extension table.
    func languageName(for url: URL) -> String? {
        let filename = url.lastPathComponent.lowercased()
        if Self.isDotenvFilename(filename) {
            return "ini"
        }
        if Self.isIgnoreFilename(url) {
            return "bash"
        }
        if Self.isMarkdownFilename(filename) {
            return "markdown"
        }

        switch filename {
        case _ where Self.isDockerfileFilename(filename):
            return "dockerfile"
        case "makefile":
            return "makefile"
        default:
            return languageName(forExtension: url.pathExtension)
        }
    }

    /// Map a file extension (no leading dot) to a highlight.js language
    /// name. Returns nil for unknown extensions — the editor should then
    /// skip highlighting and just use the default text colour.
    func languageName(forExtension ext: String) -> String? {
        let e = ext.lowercased()
        if Self.markdownExtensions.contains(e) { return "markdown" }
        switch e {
        case "swift": return "swift"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "ts", "tsx": return "typescript"
        case "py", "pyi": return "python"
        case "go": return "go"
        case "rs": return "rust"
        case "rb": return "ruby"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "c", "h": return "c"
        case "cpp", "cxx", "cc", "hpp", "hh", "hxx": return "cpp"
        case "m": return "objectivec"
        case "mm": return "objectivec"
        case "cs": return "csharp"
        case "php": return "php"
        case "json", "json5", "jsonc", "jsonl", "ndjson", "geojson", "map", "webmanifest", "har":
            return "json"
        case "yaml", "yml": return "yaml"
        case "toml": return "ini"
        case "ini", "conf", "cfg": return "ini"
        case "html", "htm", "svelte", "vue": return "xml"
        case "xml", "plist", "xib", "storyboard": return "xml"
        case "css": return "css"
        case "scss", "sass": return "scss"
        case "less": return "less"
        case "sh", "bash", "zsh", "fish": return "bash"
        case "ps1": return "powershell"
        case "sql": return "sql"
        case "lua": return "lua"
        case "pl", "pm": return "perl"
        case "r": return "r"
        case "scala": return "scala"
        case "clj", "cljs", "edn": return "clojure"
        case "elm": return "elm"
        case "ex", "exs": return "elixir"
        case "erl", "hrl": return "erlang"
        case "hs": return "haskell"
        case "ml", "mli": return "ocaml"
        case "fs", "fsi", "fsx": return "fsharp"
        case "dart": return "dart"
        case "groovy", "gradle": return "groovy"
        case "tex": return "latex"
        case "diff", "patch": return "diff"
        case "dockerfile": return "dockerfile"
        case "makefile", "mk": return "makefile"
        case "vim": return "vim"
        case "graphql", "gql": return "graphql"
        case "proto": return "protobuf"
        default: return nil
        }
    }

    private static func isDotenvFilename(_ filename: String) -> Bool {
        filename == ".env" || filename.hasPrefix(".env.")
    }

    private static func isDockerfileFilename(_ filename: String) -> Bool {
        filename == "dockerfile"
            || filename == "containerfile"
            || filename.hasPrefix("dockerfile.")
            || filename.hasPrefix("containerfile.")
            || filename.hasSuffix(".dockerfile")
            || filename.hasSuffix(".containerfile")
    }

    private static func isIgnoreFilename(_ url: URL) -> Bool {
        let filename = url.lastPathComponent.lowercased()
        if filename == ".gitignore"
            || filename == ".dockerignore"
            || filename == ".ignore"
            || filename.hasSuffix(".gitignore")
            || filename.hasSuffix(".dockerignore")
            || filename.hasSuffix(".ignore") {
            return true
        }
        return url.path.hasSuffix("/.git/info/exclude")
    }

    private static func isMarkdownFilename(_ filename: String) -> Bool {
        switch filename {
        case "readme", "changelog", "contributing", "code_of_conduct",
             "security", "support", "authors", "notice", "license":
            return true
        default:
            return false
        }
    }

    /// Markdown file extensions (no leading dot). Single source of truth so
    /// the editor's "Preview" affordance and the highlighter's grammar
    /// selection always agree on what counts as Markdown.
    static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdx", "mdc", "mdown", "mkd", "mkdn", "mdwn", "mdtxt"
    ]

    /// Whether `url` is a Markdown document — by extension (`.md`, `.markdown`,
    /// …) or by the by-convention bare filenames (`README`, `CHANGELOG`, …).
    /// Used by the editor to decide whether to offer a rendered preview.
    static func isMarkdown(_ url: URL) -> Bool {
        if isMarkdownFilename(url.lastPathComponent.lowercased()) { return true }
        return markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Skip highlighting if the document is too large — JSContext is
    /// single-threaded and runs on the calling thread, so a multi-MB
    /// minified file would otherwise wedge the main runloop.
    func shouldHighlight(byteCount: Int) -> Bool {
        byteCount <= Self.maxBytesToHighlight
    }

    /// Compute per-token colours for `text` interpreted as `language`.
    /// Pure (no UI access), so safe to run off main. Returns the
    /// attributed string Highlightr produced; callers extract the
    /// foreground-colour ranges from it.
    func attributedHighlight(text: String, language: String) -> NSAttributedString? {
        // Highlightr reuses its internal JSContext, so this is just a
        // string-in / string-out call. Still, it's synchronous CPU work
        // that we want off the main thread for big files.
        renderQueue.sync {
            highlightr?.highlight(text, as: language, fastRender: true)
        }
    }

    /// Apply the foreground-colour ranges from `attributed` onto `storage`,
    /// preserving the storage's existing string. Caller already grabbed
    /// `attributed` off the main thread; this method must run on main
    /// because `NSTextStorage` is not thread-safe.
    @MainActor
    func applyForegroundColors(_ attributed: NSAttributedString,
                               to storage: NSTextStorage,
                               expectedText: String? = nil) {
        // Avoid drift: if the storage's text has changed since `attributed`
        // was computed (user typed during the highlight roundtrip),
        // applying stale ranges could clobber unrelated regions. Bail and
        // let the next debounce tick re-run.
        guard attributed.length == storage.length else { return }
        if let expectedText, storage.string != expectedText { return }
        storage.beginEditing()
        let full = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.foregroundColor, range: full)
        attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let color = value as? NSColor {
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        storage.endEditing()
    }

    /// Reset the storage's foreground to the system label colour — used
    /// when the user opens an unknown extension and the previous tab's
    /// colours would otherwise leak through.
    @MainActor
    func clearColors(in storage: NSTextStorage, defaultColor: NSColor = .labelColor) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: full)
        storage.addAttribute(.foregroundColor, value: defaultColor, range: full)
        storage.endEditing()
    }
}
