import Foundation

enum AIError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Invalid AI provider endpoint"
        case .invalidResponse: "Invalid response from AI provider"
        case let .apiError(code, msg): "AI API error (\(code)): \(msg)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .invalidEndpoint, .invalidResponse: false
        case let .apiError(code, _): code >= 500
        }
    }
}
