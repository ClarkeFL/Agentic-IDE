import Foundation
import Observation

/// Per-project poller that exposes a path → `GitFileStatus` map for the
/// file-tree pane. Polls `git status` every `pollIntervalSeconds` while
/// `isPolling` is true. The file tree owns the watcher's lifetime via
/// `.task(id:)`, so a project switch starts polling for the new project
/// and cancels the previous loop.
///
/// In addition to leaf-file statuses we also surface a directory rollup:
/// if any descendant of `dir` is in `fileStatuses`, the most-severe status
/// among them is recorded in `folderStatuses[dir]`. The tree uses this to
/// dot a folder row when something inside has changed even though the
/// folder itself isn't expanded.
@Observable
final class GitStatusWatcher {
    /// Absolute-path → status for every file currently flagged by git.
    var fileStatuses: [String: GitFileStatus] = [:]
    /// Absolute-path → most-severe descendant status. Includes both the
    /// project root and every interior directory between root and a
    /// changed file.
    var folderStatuses: [String: GitFileStatus] = [:]
    /// Raw change records — backs the "Changes" pane mode and the footer's
    /// commit-button enabled state. Sorted by directory then filename.
    var changes: [GitChange] = []
    /// Current branch name (or "(<sha>)" when detached). Nil = not a repo.
    var branch: String?
    /// Local branch names (recent first). Backs the footer's switch menu.
    var localBranches: [String] = []
    /// How many local commits aren't on the upstream. Drives the Push
    /// badge.
    var ahead: Int = 0
    /// How many upstream commits aren't local yet. Drives the Pull badge.
    var behind: Int = 0
    /// True when the branch has no upstream configured. Hides the
    /// ahead/behind pills (there's nothing to compare to).
    var hasUpstream: Bool = false
    /// True when the last `git status` ran successfully. Flips to false
    /// when the project isn't a git repo (or git is otherwise unavailable).
    var isGitRepo: Bool = true
    /// Open GitHub pull request for the current branch, when GitHub CLI can
    /// resolve one. Nil means no PR or unavailable lookup.
    var pullRequest: GitService.PullRequestInfo?

    let projectId: UUID
    let rootPath: URL

    /// 4 seconds matches the cadence the retired right inspector used. Long
    /// enough that idle CPU stays near zero; short enough that the user
    /// sees their `git add`/`commit` reflected in the tree quickly.
    private let pollIntervalSeconds: UInt64 = 4

    init(projectId: UUID, rootPath: URL) {
        self.projectId = projectId
        self.rootPath = rootPath
    }

    /// Drives the polling loop — the file tree calls this from a
    /// `.task(id: project.id)` so cancellation is automatic on project
    /// switch / view disappear.
    func runPollLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: pollIntervalSeconds * 1_000_000_000)
        }
    }

    /// One-shot refresh — called from the poll loop and on demand from the
    /// tree's manual refresh button.
    @MainActor
    func refresh() async {
        async let statusTask = GitService.status(at: rootPath)
        async let branchTask = GitService.currentBranch(at: rootPath)
        async let aheadBehindTask = GitService.aheadBehind(at: rootPath)
        async let branchesTask = GitService.localBranches(at: rootPath)

        let statusResult = await statusTask
        let branchResult = await branchTask
        let aheadBehindResult = await aheadBehindTask
        let branchesResult = await branchesTask

        guard let raw = statusResult else {
            isGitRepo = false
            fileStatuses = [:]
            folderStatuses = [:]
            changes = []
            branch = nil
            localBranches = []
            ahead = 0
            behind = 0
            hasUpstream = false
            pullRequest = nil
            return
        }
        isGitRepo = true
        branch = branchResult
        localBranches = branchesResult
        async let pullRequestTask = GitService.pullRequest(at: rootPath)
        if let pair = aheadBehindResult {
            ahead = pair.ahead
            behind = pair.behind
            hasUpstream = true
        } else {
            ahead = 0
            behind = 0
            hasUpstream = false
        }
        pullRequest = await pullRequestTask
        var files: [String: GitFileStatus] = [:]
        var folders: [String: GitFileStatus] = [:]
        for change in raw {
            files[change.url.standardizedFileURL.path] = change.status
            // Walk every ancestor up to the project root, recording the
            // most-severe status seen so far. Severity rank: conflict >
            // deleted > modified > added > renamed > untracked.
            var dir = change.url.deletingLastPathComponent()
            let rootStd = rootPath.standardizedFileURL.path
            while dir.path.hasPrefix(rootStd) {
                let key = dir.standardizedFileURL.path
                let prior = folders[key]
                folders[key] = mergeStatus(prior, change.status)
                if dir.path == rootStd { break }
                dir = dir.deletingLastPathComponent()
            }
        }
        fileStatuses = files
        folderStatuses = folders
        changes = raw
    }

    /// Status read for a single absolute path. Convenience wrapper so call
    /// sites don't have to standardise the URL themselves.
    func status(for url: URL) -> GitFileStatus? {
        fileStatuses[url.standardizedFileURL.path]
    }

    /// Folder rollup status read.
    func folderStatus(for url: URL) -> GitFileStatus? {
        folderStatuses[url.standardizedFileURL.path]
    }

    /// Pick the more-severe of two statuses for the folder rollup. The
    /// ordering matches what users tend to scan for: conflicts demand
    /// attention first, deletions are loud, modifications are common.
    private func mergeStatus(_ a: GitFileStatus?, _ b: GitFileStatus) -> GitFileStatus {
        guard let a else { return b }
        return rank(a) >= rank(b) ? a : b
    }

    private func rank(_ status: GitFileStatus) -> Int {
        switch status {
        case .conflicted: return 6
        case .deleted:    return 5
        case .modified:   return 4
        case .added:      return 3
        case .renamed:    return 2
        case .untracked:  return 1
        }
    }
}

/// One `GitStatusWatcher` per project, lazily created. Mirrors
/// `EditorSessionManager`'s shape so that switching projects doesn't drop
/// the previously polled status — switching back is instant.
@Observable
final class GitStatusWatcherStore {
    private var watchers: [UUID: GitStatusWatcher] = [:]

    func watcher(for projectId: UUID, rootPath: URL) -> GitStatusWatcher {
        if let w = watchers[projectId] { return w }
        let w = GitStatusWatcher(projectId: projectId, rootPath: rootPath)
        watchers[projectId] = w
        return w
    }

    func discard(projectId: UUID) {
        watchers.removeValue(forKey: projectId)
    }
}
