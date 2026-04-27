import Foundation

/// A project folder the user has added to the sidebar. Persisted to disk.
struct Project: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    /// Stored as a string and rehydrated to URL on access — bookmarks would be
    /// better for sandbox-survival, but we run un-sandboxed in v1.
    var pathString: String
    var quickLaunches: [QuickLaunch]
    var lastActivityAt: Date?
    var lastActivityCommand: String?
    var archived: Bool
    /// Group this project belongs to. nil means "Ungrouped".
    var groupId: UUID?

    init(id: UUID = UUID(),
         name: String,
         path: URL,
         quickLaunches: [QuickLaunch] = QuickLaunch.defaults(),
         lastActivityAt: Date? = nil,
         lastActivityCommand: String? = nil,
         archived: Bool = false,
         groupId: UUID? = nil) {
        self.id = id
        self.name = name
        self.pathString = path.path
        self.quickLaunches = quickLaunches
        self.lastActivityAt = lastActivityAt
        self.lastActivityCommand = lastActivityCommand
        self.archived = archived
        self.groupId = groupId
    }

    var path: URL { URL(fileURLWithPath: pathString) }
}
