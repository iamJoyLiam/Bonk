import Foundation
import Observation

/// Where the AI agent should operate.
enum AgentTarget: Equatable {
    /// The currently active terminal tab's SSH session.
    case activeTab
    /// A saved host, connected on demand with stored credentials.
    case host(UUID)

    var id: String {
        switch self {
        case .activeTab: "activeTab"
        case .host(let hostID): hostID.uuidString
        }
    }
}

/// Shared AI agent target selection.
@Observable @MainActor
final class AgentTargetStore {
    static let shared = AgentTargetStore()

    var target: AgentTarget = .activeTab

    private init() {}
}
