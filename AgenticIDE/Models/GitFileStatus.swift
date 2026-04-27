import SwiftUI

/// Working-tree status for a single path, collapsed from porcelain=v2's
/// staged/unstaged pair into one user-facing flag.
enum GitFileStatus: String, Codable, Hashable {
    case untracked
    case modified
    case added
    case deleted
    case renamed
    case conflicted

    /// Single-character indicator rendered inside the status badge.
    var indicator: String {
        switch self {
        case .untracked: return "U"
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .conflicted: return "!"
        }
    }

    /// Full word used in tooltips and accessibility labels.
    var label: String {
        switch self {
        case .untracked: return "Untracked"
        case .modified: return "Modified"
        case .added: return "Added (staged)"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .conflicted: return "Conflict"
        }
    }

    /// Background color for the status badge / tree decoration. Picked so
    /// the six statuses are quickly distinguishable at a glance.
    var tint: Color {
        switch self {
        case .untracked: return Color(red: 0.22, green: 0.78, blue: 0.45) // green
        case .added:     return Color(red: 0.18, green: 0.65, blue: 0.85) // teal
        case .modified:  return Color(red: 0.92, green: 0.68, blue: 0.20) // amber
        case .renamed:   return Color(red: 0.55, green: 0.45, blue: 0.95) // purple
        case .deleted:   return Color(red: 0.90, green: 0.30, blue: 0.30) // red
        case .conflicted:return Color(red: 0.95, green: 0.45, blue: 0.18) // orange
        }
    }
}

/// Where in the staging pipeline the change currently sits. `.both` means
/// the file has staged changes plus further unstaged edits on top.
enum StageState: String, Codable, Hashable {
    case unstaged   // working tree only (Y in porcelain XY pair)
    case staged     // index only (X in porcelain XY pair)
    case both       // both index and working tree differ
    case untracked  // never `git add`ed
    case conflict   // unmerged
}

/// One row in the changed-files list. `url` is absolute; `relativePath`
/// is what we show and pass to `git diff`.
struct GitChange: Identifiable, Hashable {
    let url: URL
    let relativePath: String
    let status: GitFileStatus
    let stageState: StageState
    /// Lines added in the working tree relative to HEAD. For untracked
    /// files this is the file's line count; for deleted it's 0.
    var additions: Int = 0
    /// Lines removed relative to HEAD. 0 for untracked / added.
    var deletions: Int = 0

    var id: URL { url }
    var displayName: String { (relativePath as NSString).lastPathComponent }
    var directoryName: String {
        let dir = (relativePath as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }

    /// Short status sentence shown under the filename, e.g.
    /// "Modified · Unstaged", "Added · Staged", "Untracked".
    var stateSubtitle: String {
        switch stageState {
        case .untracked: return "Untracked"
        case .conflict:  return "Conflict — needs resolve"
        case .unstaged:  return "\(status.label) · Unstaged"
        case .staged:    return "\(status.label) · Staged"
        case .both:      return "\(status.label) · Staged + Unstaged"
        }
    }
}

/// Filled rounded-rect badge with a single white letter inside. Sized so
/// it reads at a glance and aligns with the leading edge of a row.
struct StatusBadge: View {
    let status: GitFileStatus
    var size: CGFloat = 14

    var body: some View {
        Text(status.indicator)
            .font(.system(size: size * 0.68, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size + 2, height: size)
            .background(status.tint, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .accessibilityLabel(status.label)
    }
}
