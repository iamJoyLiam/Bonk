import Foundation

/// Policy for AI provider network connections.
enum AIConnectionPolicy: String, CaseIterable, Identifiable {
    case alwaysAllow, askEachTime, never

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alwaysAllow: return I18n.shared.t(.alwaysAllow)
        case .askEachTime: return I18n.shared.t(.askEachTime)
        case .never:       return I18n.shared.t(.never)
        }
    }
}
