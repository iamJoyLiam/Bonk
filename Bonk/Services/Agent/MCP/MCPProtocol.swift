//
//  MCPProtocol.swift
//  Bonk
//
//  The Model Context Protocol's wire shapes.
//
//  Only what a **client** needs: the initialize handshake, listing a
//  server's tools, and calling one. The server side of MCP — resources,
//  prompts, sampling, elicitation — is not implemented and not needed
//  for the agent to use a server's tools.
//
//  The layering follows Pi's `packages/mcp`: the protocol types know
//  nothing about how the bytes travel, so the same client core works
//  over a subprocess pipe, over HTTP, or over an in-memory pipe.
//
//  Two decisions worth stating:
//
//  **The request id is a string on the wire.** JSON-RPC allows a number
//  or a string, and servers are not always careful to echo the type they
//  were given. Ids are compared by their string form, so a server that
//  turns `1` into `"1"` still matches the request it answers.
//
//  **The protocol version is checked, not assumed.** A server that picks
//  a version this client does not know is refused rather than talked to,
//  because the shapes below are version-specific.
//

import Foundation

// MARK: - The protocol version

enum MCPProtocol {
    /// The version this client asks for.
    static let latestVersion = "2025-11-25"

    /// The versions this client accepts a server to answer with.
    ///
    /// A server that does not support the requested version answers with
    /// its own latest one, so older servers stay usable.
    static let supportedVersions: [String] = [
        latestVersion,
        "2025-06-18",
        "2025-03-26",
        "2024-11-05"
    ]

    static func isSupported(_ version: String) -> Bool {
        supportedVersions.contains(version)
    }
}

// MARK: - JSON

/// A JSON value.
///
/// `JSONSerialization` hands back `Any`, which is neither `Sendable` nor
/// equatable, and MCP messages cross actor boundaries. This is the small
/// subset that is.
enum MCPJSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])

    /// The value as a string, when it is one.
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// The value as a number, when it is one.
    var numberValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    /// The value as a bool, when it is one.
    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    /// The value as an object, when it is one.
    var objectValue: [String: MCPJSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// The value as an array, when it is one.
    var arrayValue: [MCPJSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// The number as it would be written on the wire.
    ///
    /// `1` and `1.0` are the same id to a server that echoes what it was
    /// given; keeping one spelling makes the comparison stable.
    var numericText: String? {
        guard case let .number(value) = self else { return nil }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }
}

// MARK: - JSON-RPC

/// The JSON-RPC errors the protocol defines.
enum MCPJSONRPCErrorCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

/// A failure the server reported.
struct MCPJSONRPCError: Error, Sendable, Equatable {
    let code: Int
    let message: String
    let data: MCPJSONValue?

    init(code: Int, message: String, data: MCPJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// A message on the wire.
enum MCPJSONRPCMessage: Sendable, Equatable {
    /// A request from one side to the other.
    case request(id: String, method: String, params: MCPJSONValue?)
    /// A notification: a request without an answer.
    case notification(method: String, params: MCPJSONValue?)
    /// A successful answer to a request.
    case response(id: String, result: MCPJSONValue)
    /// A failed answer to a request.
    case failure(id: String, error: MCPJSONRPCError)

    /// The request id, when the message answers a request.
    var responseId: String? {
        switch self {
        case let .response(id, _), let .failure(id, _): return id
        case .request, .notification: return nil
        }
    }
}

// MARK: - The method names

enum MCPMethod {
    static let initialize = "initialize"
    static let initialized = "notifications/initialized"
    static let toolsList = "tools/list"
    static let toolsCall = "tools/call"
}

// MARK: - Handshake

/// What the client tells the server.
struct MCPClientInfo: Sendable, Equatable {
    let name: String
    let version: String
}

/// What the server tells the client.
struct MCPServerInfo: Sendable, Equatable {
    let name: String
    let version: String
}

/// The server's answer to `initialize`.
struct MCPInitializeResult: Sendable, Equatable {
    let protocolVersion: String
    let serverInfo: MCPServerInfo
    /// The server's own instructions for the model, if it has any.
    let instructions: String?
}

// MARK: - Tools

/// One tool a server offers.
///
/// `inputSchema` is kept as raw JSON: it is already a JSON Schema, and
/// re-modelling it would only lose fields this client does not know.
struct MCPToolDescriptor: Sendable, Equatable {
    let name: String
    let title: String?
    let description: String?
    let inputSchema: MCPJSONValue?
    /// The server's own hints: read-only, destructive, idempotent.
    let annotations: MCPJSONValue?
}

// MARK: - Tool results

/// One piece of a tool's answer.
enum MCPContentBlock: Sendable, Equatable {
    case text(String)
    case other(kind: String)

    var text: String? {
        if case let .text(value) = self { return value }
        return nil
    }
}

/// What `tools/call` answered.
struct MCPToolCallResult: Sendable, Equatable {
    let content: [MCPContentBlock]
    /// The server says the call failed — a tool error, not a transport error.
    let isError: Bool

    /// The answer as the model will see it.
    ///
    /// Only text reaches the model: a picture or an embedded resource has
    /// no representation in a text conversation, and pretending otherwise
    /// would send the model a marker it cannot act on. A non-text block
    /// becomes a short note saying what kind of thing it was.
    var textForModel: String {
        let parts: [String] = content.compactMap { block in
            switch block {
            case let .text(value): return value
            case let .other(kind): return "[non-text content: \(kind)]"
            }
        }
        return parts.joined(separator: "\n")
    }
}
