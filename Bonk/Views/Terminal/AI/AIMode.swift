import SwiftUI

enum AIMode: String, CaseIterable {
    case ask = "Ask"
    case agent = "Agent"

    var icon: String {
        switch self {
        case .ask: "bubble.left.and.text.bubble.right"
        case .agent: "bolt.circle"
        }
    }

    var localizedName: String {
        switch self {
        case .ask: L.t(.aiModeAsk)
        case .agent: L.t(.aiModeAgent)
        }
    }

    var description: String {
        switch self {
        case .ask: L.t(.aiModeAskDesc)
        case .agent: L.t(.aiModeAgentDesc)
        }
    }
}
