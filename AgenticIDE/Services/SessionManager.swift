import Foundation
import Observation

/// Maps Project.id to its in-memory ProjectSession. Sessions are created
/// lazily on first activation and retained for the rest of the app's lifetime
/// so terminals keep running across project switches.
@Observable
final class SessionManager {
    private var sessions: [UUID: ProjectSession] = [:]

    func session(for projectId: UUID) -> ProjectSession {
        if let existing = sessions[projectId] { return existing }
        let s = ProjectSession(projectId: projectId)
        sessions[projectId] = s
        return s
    }

    func discard(projectId: UUID) {
        sessions.removeValue(forKey: projectId)
    }
}
