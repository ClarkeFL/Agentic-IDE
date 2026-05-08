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

    /// Cheap newline count via mmap. Capped at `maxScanBytes` so a
    /// pathological untracked file (multi-GB log, mistakenly-committed
    /// asset, etc.) can't pin the git queue scanning bytes during a 5s
    /// status poll. When the cap is hit the count is a lower bound; the
    /// inspector renders `+N` and any over-budget tail is ignored.
    private static let maxScanBytes: Int = 1 << 20  // 1 MiB
    private static func countLines(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url, options: [.alwaysMapped]) else { return 0 }
        if data.isEmpty { return 0 }
        let scanLen = Swift.min(data.count, maxScanBytes)
        var count = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<scanLen where bytes[i] == 0x0A { count += 1 }
        }
        if data.count <= maxScanBytes && data.last != 0x0A { count += 1 }
        return count
    }

    /// Returns the file's contents at HEAD (i.e. the last committed
    /// version) as a UTF-8 string, or `nil` if the file is untracked /
    /// brand-new / not in HEAD. Used by the editor's side-by-side diff
    /// view as the "before" panel.
    static func headContent(at root: URL, file: URL) async -> String? {
        guard let rel = relativePath(of: file, in: root) else { return nil }
        let raw = await run(args: ["-C", root.path,
                                    "show", "HEAD:\(rel)"],
                            in: root,
                            allowNonZeroExit: true)
        return raw
    }

    /// Current branch name, e.g. `"dev"` / `"main"`. Returns `nil` if
    /// detached HEAD (we surface a short SHA in the footer in that case),
    /// or the directory isn't a git repo.
    static func currentBranch(at root: URL) async -> String? {
        let raw = await run(args: ["-C", root.path,
                                    "symbolic-ref", "--quiet", "--short", "HEAD"],
                            in: root,
                            allowNonZeroExit: true)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        // Detached HEAD — fall back to a short sha so the footer still has
        // something meaningful to show.
        let sha = await run(args: ["-C", root.path,
                                    "rev-parse", "--short", "HEAD"],
                            in: root,
                            allowNonZeroExit: true)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let sha, !sha.isEmpty { return "(\(sha))" }
        return nil
    }

    /// Returns `(ahead, behind)` relative to the upstream branch — i.e.
    /// how many commits the local has that upstream doesn't, and vice
    /// versa. `nil` when there's no upstream configured (e.g. a fresh
    /// branch that hasn't been pushed yet) or git failed.
    static func aheadBehind(at root: URL) async -> (ahead: Int, behind: Int)? {
        let raw = await run(args: ["-C", root.path,
                                    "rev-list", "--left-right", "--count",
                                    "HEAD...@{u}"],
                            in: root,
                            allowNonZeroExit: true)
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Output is "<ahead>\t<behind>" — left is HEAD-only, right is
        // upstream-only.
        let parts = trimmed.split(whereSeparator: { $0 == "\t" || $0 == " " })
        guard parts.count == 2,
              let ahead = Int(parts[0]),
              let behind = Int(parts[1]) else { return nil }
        return (ahead, behind)
    }

    // MARK: - Mutating actions
    //
    // All four return `(ok, output)` so the UI can pop an alert with git's
    // own stderr on failure (more useful than a generic "git failed"). The
    // callers wrap these in alerts; we never throw.

    /// `git fetch` — refreshes remote-tracking refs without touching the
    /// working tree. Safe to run from a button.
    static func fetch(at root: URL) async -> (ok: Bool, output: String) {
        await runReportingExit(args: ["-C", root.path, "fetch"], in: root)
    }

    /// `git pull --ff-only`. Refuses to merge when the local has diverged
    /// — surfaces git's "not possible to fast-forward" error verbatim so
    /// the user knows to rebase / merge themselves rather than us doing
    /// it silently.
    static func pull(at root: URL) async -> (ok: Bool, output: String) {
        await runReportingExit(args: ["-C", root.path, "pull", "--ff-only"], in: root)
    }

    /// `git push`. If the branch has no upstream this fails — caller can
    /// inspect `output` and offer `--set-upstream` separately if we ever
    /// build that flow.
    static func push(at root: URL) async -> (ok: Bool, output: String) {
        await runReportingExit(args: ["-C", root.path, "push"], in: root)
    }

    /// `git add -A` followed by `git commit -m <msg>`. Stages everything
    /// including untracked + deletions, mirroring what most desktop
    /// clients call "Commit All". Returns the commit's stderr/stdout on
    /// failure so the user sees git's own message.
    static func commitAll(at root: URL, message: String) async -> (ok: Bool, output: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (false, "Commit message can't be empty.") }
        let stage = await runReportingExit(args: ["-C", root.path, "add", "-A"], in: root)
        guard stage.ok else { return stage }
        return await runReportingExit(args: ["-C", root.path,
                                              "commit", "-m", trimmed],
                                       in: root)
    }

    /// Same shape as `run` but always returns whether the exit was zero
    /// plus the combined stdout+stderr (we want stderr on failure).
    private static func runReportingExit(args: [String], in cwd: URL) async -> (ok: Bool, output: String) {
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

                let outBuf = AtomicData()
                let errBuf = AtomicData()
                let group = DispatchGroup()
                group.enter(); group.enter()
                drainQueue.async {
                    outBuf.set(stdout.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
                drainQueue.async {
                    errBuf.set(stderr.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
                do {
                    try process.run()
                } catch {
                    group.wait()
                    continuation.resume(returning: (false, error.localizedDescription))
                    return
                }
                process.waitUntilExit()
                group.wait()
                let out = String(data: outBuf.get(), encoding: .utf8) ?? ""
                let err = String(data: errBuf.get(), encoding: .utf8) ?? ""
                let combined = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
                continuation.resume(returning: (process.terminationStatus == 0, combined))
            }
        }
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
    ///
    /// Both pipes are drained on background queues *while* the child runs so
    /// neither stdout nor stderr can fill its 64 KiB pipe buffer and block
    /// git from exiting. The previous shape (`waitUntilExit` then read
    /// stdout) deadlocked on diffs larger than the pipe buffer because the
    /// child blocked writing while we blocked waiting for it to exit.
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

                let outBuf = AtomicData()
                let errBuf = AtomicData()
                let drainGroup = DispatchGroup()
                drainGroup.enter()
                drainGroup.enter()
                drainQueue.async {
                    outBuf.set(stdout.fileHandleForReading.readDataToEndOfFile())
                    drainGroup.leave()
                }
                drainQueue.async {
                    errBuf.set(stderr.fileHandleForReading.readDataToEndOfFile())
                    drainGroup.leave()
                }

                do {
                    try process.run()
                } catch {
                    // The drain reads will return immediately on the closed
                    // pipes; wait so we don't leak the dispatch_group.
                    drainGroup.wait()
                    log.error("git launch failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                process.waitUntilExit()
                drainGroup.wait()

                let output = String(data: outBuf.get(), encoding: .utf8) ?? ""

                if process.terminationStatus != 0 && !allowNonZeroExit {
                    let err = String(data: errBuf.get(), encoding: .utf8) ?? ""
                    log.debug("git \(args.joined(separator: " "), privacy: .public) exited \(process.terminationStatus): \(err, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: output)
            }
        }
    }

    /// Concurrent queue for the per-process stdout/stderr drains. Two reads
    /// per `run()` invocation, both short-lived; a concurrent queue lets
    /// many in-flight git invocations drain in parallel without one waiting
    /// behind another's stderr read.
    private static let drainQueue = DispatchQueue(label: "com.fabio.AgenticIDE.git.drain",
                                                  qos: .userInitiated,
                                                  attributes: .concurrent)

    /// Tiny lock-protected `Data` slot. The drain closures run on the
    /// concurrent `drainQueue` and the result is read back on the calling
    /// thread after a `DispatchGroup.wait()`; the lock is just to satisfy
    /// the formal happens-before rule (the wait already provides the
    /// synchronization in practice).
    private final class AtomicData {
        private var value: Data = Data()
        private let lock = NSLock()
        func set(_ d: Data) { lock.lock(); value = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
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
