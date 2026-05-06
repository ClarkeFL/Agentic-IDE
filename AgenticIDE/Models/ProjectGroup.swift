import Foundation

/// A user-named bucket projects can belong to (e.g. "Work", "Personal").
/// Persisted alongside projects in `projects.json`.
struct ProjectGroup: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var sortOrder: Int
    var collapsed: Bool

    init(id: UUID = UUID(), name: String, sortOrder: Int = 0, collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.collapsed = collapsed
    }

    enum CodingKeys: String, CodingKey {
        case id, name, sortOrder, collapsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        collapsed = try container.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }
}
