import Foundation

/// A project folder the user has added to the sidebar. Persisted to disk.
struct Project: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    /// Stored as a string and rehydrated to URL on access — bookmarks would be
    /// better for sandbox-survival, but we run un-sandboxed in v1.
    var pathString: String
    var quickLaunches: [QuickLaunch]
    /// Named dev servers for this project (name + command). Run all or a subset
    /// into a dedicated "Servers" workspace from the bottom server bar.
    var servers: [QuickLaunch]
    var lastActivityAt: Date?
    var lastActivityCommand: String?
    var archived: Bool
    /// Group this project belongs to. nil means "Ungrouped".
    var groupId: UUID?

    init(id: UUID = UUID(),
         name: String,
         path: URL,
         quickLaunches: [QuickLaunch] = QuickLaunch.defaults(),
         servers: [QuickLaunch] = [],
         lastActivityAt: Date? = nil,
         lastActivityCommand: String? = nil,
         archived: Bool = false,
         groupId: UUID? = nil) {
        self.id = id
        self.name = name
        self.pathString = path.path
        self.quickLaunches = quickLaunches
        self.servers = servers
        self.lastActivityAt = lastActivityAt
        self.lastActivityCommand = lastActivityCommand
        self.archived = archived
        self.groupId = groupId
    }

    var path: URL { URL(fileURLWithPath: pathString) }

    // Custom decoder so projects.json written before `servers` existed still
    // loads (synthesized Decodable would throw on the missing key). Encoding
    // stays synthesized.
    enum CodingKeys: String, CodingKey {
        case id, name, pathString, quickLaunches, servers
        case lastActivityAt, lastActivityCommand, archived, groupId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        pathString = try c.decode(String.self, forKey: .pathString)
        quickLaunches = try c.decode([QuickLaunch].self, forKey: .quickLaunches)
        servers = try c.decodeIfPresent([QuickLaunch].self, forKey: .servers) ?? []
        lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        lastActivityCommand = try c.decodeIfPresent(String.self, forKey: .lastActivityCommand)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        groupId = try c.decodeIfPresent(UUID.self, forKey: .groupId)
    }
}
