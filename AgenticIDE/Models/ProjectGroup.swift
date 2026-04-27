import Foundation

/// A user-named bucket projects can belong to (e.g. "Work", "Personal").
/// Persisted alongside projects in `projects.json`.
struct ProjectGroup: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var sortOrder: Int

    init(id: UUID = UUID(), name: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }
}
