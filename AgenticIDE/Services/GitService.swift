import Foundation
import OSLog

/// Thin wrapper around `/usr/bin/git`. Stateless — every call shells out.
/// Callers throttle as they see fit (the right inspector polls every few
/// seconds while visible, and re-fetches the diff on file selection).
enum GitService {
    private static let log = Logger(subsystem: "com.fabio.AgenticIDE", category: "GitService")
    private static let queue = DispatchQueue(label: "com.fabio.AgenticIDE.git",
                                             qos: .userInitiated,
                                             attributes: .concurrent)

    /// Returns the list of changed paths in `root`, enriched with per-file
    /// +/- line counts. Returns `nil` if `root` is not a git repo (or git
    /// failed for any reason).
    static func status(at root: URL) async -> [GitChange]? {
        async let statusRaw = run(args: ["-C", root.path,
                                          "status", "--porcelain=v2",
                                          "--untracked-files=all"],
                                  in: root)
        async let numstatRaw = run(args: ["-C", root.path,
                                           "diff", "--numstat", "HEAD"],
                                   in: root,
                                   allowNonZeroExit: true)
        guard let raw = await statusRaw else { return nil }
        let stats = parseNumstat(await numstatRaw ?? "")
        var changes = parsePorcelainV2(raw, root: root)
        for i in changes.indices {
            if let pair = stats[changes[i].relativePath] {
                changes[i].additions = pair.additions
                changes[i].deletions = pair.deletions
            } else if changes[i].stageState == .untracked {
                changes[i].additions = countLines(at: changes[i].url)
            }
        }
        return changes
    }

    /// Parses `git diff --numstat`. Each line is `<adds>\t<dels>\t<path>`,
    /// or `-\t-\t<path>` for binary files (we surface those as 0/0).
    private static func parseNumstat(_ raw: String) -> [String: (additions: Int, deletions: Int)] {
        var result: [String: (Int, Int)] = [:]
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let adds = Int(parts[0]) ?? 0
            let dels = Int(parts[1]) ?? 0
            result[String(parts[2])] = (adds, dels)
        }
        return result
    }

    /// Cheap newline count via mmap. For very large files this is still
    /// O(file size) but reads sequentially through pages, no heap alloc
    /// for the contents. Returns 0 if the file is missing or binary-ish.
    private static func countLines(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url, options: [.alwaysMapped]) else { return 0 }
        if data.isEmpty { return 0 }
        var count = 0
        data.withUnsafeBytes { buffer in
            for byte in buffer where byte == 0x0A { count += 1 }
        }
        if data.last != 0x0A { count += 1 }
        return count
    }

    /// Returns the unified diff for `file` against HEAD (for tracked files)
    /// or against /dev/null (for untracked files). Empty string means the
    /// file matches HEAD or doesn't exist.
    static func diff(at root: URL, file: URL, isUntracked: Bool) async -> String {
        let rel = relativePath(of: file, in: root) ?? file.lastPathComponent
        let args: [String]
        if isUntracked {
            args = ["-C", root.path,
                    "diff", "--no-color", "--no-index", "--", "/dev/null", rel]
        } else {
            args = ["-C", root.path,
                    "diff", "--no-color", "HEAD", "--", rel]
        }
        return await run(args: args, in: root, allowNonZeroExit: true) ?? ""
    }

    // MARK: - Internals

    /// Runs `/usr/bin/git` with the given args. Returns stdout as a string,
    /// or nil on launch failure / non-zero exit (unless `allowNonZeroExit`).
    private static func run(args: [String],
                            in cwd: URL,
                            allowNonZeroExit: Bool = false) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = args
                process.currentDirectoryURL = cwd

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    log.error("git launch failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                process.waitUntilExit()

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData, encoding: .utf8) ?? ""

                if process.terminationStatus != 0 && !allowNonZeroExit {
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    log.debug("git \(args.joined(separator: " "), privacy: .public) exited \(process.terminationStatus): \(err, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: output)
            }
        }
    }

    /// Parses `git status --porcelain=v2` output into [GitChange]. Spec:
    /// https://git-scm.com/docs/git-status#_porcelain_format_version_2
    ///   `1 <XY> ... <path>`        — ordinary changed entry
    ///   `2 <XY> ... <path>\t<orig>` — renamed / copied
    ///   `u <XY> ... <path>`         — unmerged
    ///   `? <path>`                  — untracked
    ///   `! <path>`                  — ignored (we skip)
    ///   `# ...`                     — header (we skip)
    private static func parsePorcelainV2(_ raw: String, root: URL) -> [GitChange] {
        var changes: [GitChange] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = line.first else { continue }
            switch first {
            case "1":
                if let change = parseOrdinaryEntry(line: String(line), root: root) {
                    changes.append(change)
                }
            case "2":
                if let change = parseRenamedEntry(line: String(line), root: root) {
                    changes.append(change)
                }
            case "u":
                if let change = parseUnmergedEntry(line: String(line), root: root) {
                    changes.append(change)
                }
            case "?":
                let rel = String(line.dropFirst(2))
                changes.append(GitChange(url: root.appendingPathComponent(rel),
                                         relativePath: rel,
                                         status: .untracked,
                                         stageState: .untracked))
            default:
                continue
            }
        }
        // Sort: directory then filename, both alphabetical.
        return changes.sorted { lhs, rhs in
            if lhs.directoryName != rhs.directoryName { return lhs.directoryName < rhs.directoryName }
            return lhs.displayName < rhs.displayName
        }
    }

    /// `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>` — path is everything
    /// after the eighth space-separated field.
    private static func parseOrdinaryEntry(line: String, root: URL) -> GitChange? {
        let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard fields.count == 9 else { return nil }
        let xy = String(fields[1])
        let path = String(fields[8])
        let (status, stage) = collapseAndStage(xy: xy)
        return GitChange(url: root.appendingPathComponent(path),
                         relativePath: path,
                         status: status,
                         stageState: stage)
    }

    /// `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>\t<orig>`
    /// — splits the trailing path / orig on tab.
    private static func parseRenamedEntry(line: String, root: URL) -> GitChange? {
        let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
        guard fields.count == 10 else { return nil }
        let xy = String(fields[1])
        let pathAndOrig = String(fields[9])
        let path = pathAndOrig.split(separator: "\t").first.map(String.init) ?? pathAndOrig
        let (_, stage) = collapseAndStage(xy: xy)
        return GitChange(url: root.appendingPathComponent(path),
                         relativePath: path,
                         status: .renamed,
                         stageState: stage)
    }

    /// `u <XY> ... <path>` — unmerged (conflict).
    private static func parseUnmergedEntry(line: String, root: URL) -> GitChange? {
        let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard fields.count == 11 else { return nil }
        let path = String(fields[10])
        return GitChange(url: root.appendingPathComponent(path),
                         relativePath: path,
                         status: .conflicted,
                         stageState: .conflict)
    }

    /// Collapse the staged/unstaged X/Y pair into a primary status plus
    /// a stage-state classifier (purely-staged / purely-unstaged / both).
    /// Prefer the unstaged side when picking the primary letter so the
    /// working tree dominates the badge.
    private static func collapseAndStage(xy: String) -> (GitFileStatus, StageState) {
        guard xy.count == 2 else { return (.modified, .unstaged) }
        let chars = Array(xy)
        let staged = chars[0]
        let unstaged = chars[1]
        let primary = unstaged != "." ? unstaged : staged
        let status: GitFileStatus
        switch primary {
        case "M": status = .modified
        case "A": status = .added
        case "D": status = .deleted
        case "R": status = .renamed
        case "C": status = .renamed
        case "U": status = .conflicted
        default:  status = .modified
        }
        let stage: StageState
        if staged != "." && unstaged != "." { stage = .both }
        else if staged != "." { stage = .staged }
        else { stage = .unstaged }
        return (status, stage)
    }

    private static func relativePath(of url: URL, in root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        guard urlPath.hasPrefix(rootPath) else { return nil }
        let drop = rootPath.hasSuffix("/") ? rootPath.count : rootPath.count + 1
        return String(urlPath.dropFirst(drop))
    }
}
