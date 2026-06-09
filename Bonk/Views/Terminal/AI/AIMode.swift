import SwiftUI

enum AIMode: String, CaseIterable {
    case ask = "Ask"
    case edit = "Edit"
    case agent = "Agent"

    var icon: String {
        switch self {
        case .ask: "questionmark.circle"
        case .edit: "pencil.circle"
        case .agent: "bolt.circle"
        }
    }

    var localizedName: String {
        switch self {
        case .ask: L.t(.aiModeAsk)
        case .edit: L.t(.aiModeEdit)
        case .agent: L.t(.aiModeAgent)
        }
    }

    var description: String {
        switch self {
        case .ask: L.t(.aiModeAskDesc)
        case .edit: L.t(.aiModeEditDesc)
        case .agent: L.t(.aiModeAgentDesc)
        }
    }
}
