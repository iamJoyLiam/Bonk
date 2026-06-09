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

    var description: String {
        switch self {
        case .ask: "Answer questions only"
        case .edit: "Suggest terminal commands"
        case .agent: "Execute commands automatically"
        }
    }
}
