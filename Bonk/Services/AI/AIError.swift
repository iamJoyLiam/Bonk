import Foundation

enum AIError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case emptyResponse
    case apiError(statusCode: Int, message: String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Invalid AI provider endpoint"
        case .invalidResponse: "Invalid response from AI provider"
        case .emptyResponse: "Empty response from AI provider"
        case let .apiError(code, msg): "AI API error (\(code)): \(msg)"
        case let .unsupported(reason): "Unsupported operation: \(reason)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .invalidEndpoint, .invalidResponse, .unsupported: false
        case .emptyResponse: true
        case let .apiError(code, _): code >= 500
        }
    }
}
