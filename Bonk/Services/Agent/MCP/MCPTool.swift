//
//  MCPTool.swift
//  Bonk
//
//  One tool of an MCP server, as an agent tool.
//
//  **The name is checked before it is used.** A server's tool list is
//  data it produced, and the name ends up in the model's tool list and
//  in the call the model makes. A name with spaces, punctuation or a
//  newline in it is not a tool name — it is a way to put text where a
//  name belongs — so such a tool is not registered at all.
//
//  **The output is data.** Whatever a server answers is the answer of a
//  program that may be talking to a system the user does not control, so
//  it is handed to the agent the way any other remote output is: as
//  untrusted content, in the envelope that says so.
//
//  **The schema's types are restored.** The agent's tools take their
//  arguments as text. An MCP tool's schema says what the arguments
//  really are, so the text is converted back before the call goes out —
//  a number stays a number, an object stays an object.
//

import Foundation

/// A tool an MCP server offers, usable by the agent.
struct MCPTool: AgentTool {
    /// The prefix every MCP tool's name carries.
    ///
    /// The prefix is what keeps a server's tool from being mistaken for
    /// one of the app's own: a server cannot name a tool `run_command`
    /// and have it run on the remote host.
    static let namePrefix = "mcp__"

    /// The separator between the server's name and the tool's name.
    static let nameSeparator = "__"

    let serverName: String
    /// The name the server gave the tool.
    let toolName: String
    let descriptor: MCPToolDescriptor
    let client: MCPClient

    /// The name the model calls this tool by.
    var name: String {
        "\(Self.namePrefix)\(serverName)\(Self.nameSeparator)\(toolName)"
    }

    var description: String {
        let text = descriptor.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            return "A tool of the MCP server '\(serverName)'."
        }
        return String(text.prefix(Self.maxDescriptionLength))
    }

    /// The longest description that goes to the model.
    ///
    /// A description is the server talking to the model. There is no
    /// reason for it to be long, and an unbounded one would crowd out the
    /// conversation.
    static let maxDescriptionLength = 2_000

    /// The largest schema that goes to the model.
    static let maxSchemaBytes = 32 * 1024

    var definition: LLMToolDefinition {
        LLMToolDefinition(
            name: name,
            description: description,
            parametersJSON: Self.parametersJSON(from: descriptor.inputSchema)
        )
    }

    func execute(
        id: String,
        arguments: [String: String],
        executionManager: AgentExecutionManager,
        executor: @escaping @Sendable (String, CommandHandleRegistration?) async throws -> (output: String, exitCode: Int32)
    ) async throws -> (output: String, exitCode: Int32) {
        let typed = Self.typedArguments(arguments, schema: descriptor.inputSchema)
        do {
            let result = try await client.callTool(name: toolName, arguments: typed)
            let text = result.textForModel
            if result.isError {
                return ("The MCP tool reported an error:\n\(text)", 1)
            }
            return (text, 0)
        } catch {
            // The failure is reported to the model rather than thrown:
            // a server that is down is something the agent can work
            // around, and the model is the one that has to decide.
            return ("The MCP call failed: \(error.localizedDescription)", 1)
        }
    }

    // MARK: - The schema

    /// The parameters the model is told about.
    static func parametersJSON(from schema: MCPJSONValue?) -> String {
        let fallback = #"{"type":"object","properties":{}}"#
        guard let schema, let object = schema.objectValue else { return fallback }
        // The schema is the server's, so it is bounded before it goes to
        // the model: a schema is a description, not a payload.
        guard let encoded = try? MCPJSONCoding.string(from: schema),
              encoded.utf8.count <= maxSchemaBytes
        else { return fallback }
        // A schema that is not an object cannot describe parameters.
        guard object["type"]?.stringValue != nil else { return fallback }
        return encoded
    }

    // MARK: - The arguments

    /// The arguments, with the types the schema asks for.
    ///
    /// The agent's tools take text. A schema that says a parameter is a
    /// number means the text has to become a number again before it is
    /// sent, or the server rejects a call the model got exactly right.
    static func typedArguments(
        _ arguments: [String: String],
        schema: MCPJSONValue?
    ) -> [String: MCPJSONValue] {
        let properties = schema?.objectValue?["properties"]?.objectValue ?? [:]
        var result: [String: MCPJSONValue] = [:]
        for (key, text) in arguments {
            let kind = properties[key]?.objectValue?["type"]?.stringValue
            result[key] = Self.value(for: text, kind: kind)
        }
        return result
    }

    /// One argument, in the type its schema asks for.
    static func value(for text: String, kind: String?) -> MCPJSONValue {
        switch kind {
        case "number":
            if let number = Double(text) { return .number(number) }
            return .string(text)
        case "integer":
            if let number = Int(text) { return .number(Double(number)) }
            return .string(text)
        case "boolean":
            if text == "true" { return .bool(true) }
            if text == "false" { return .bool(false) }
            return .string(text)
        case "object", "array":
            // The agent's tools flatten a structured argument to its
            // JSON text; it is parsed back here.
            if let data = text.data(using: .utf8),
               let parsed = try? MCPJSONCoding.value(from: data),
               parsed.objectValue != nil || parsed.arrayValue != nil
            {
                return parsed
            }
            return .string(text)
        default:
            return .string(text)
        }
    }

    // MARK: - The names

    /// A name this client is willing to put in front of a model.
    ///
    /// Letters, digits, dots, dashes and underscores, starting with a
    /// letter or a digit, and short enough to be a name.
    static func validatedName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 64,
              trimmed.range(
                of: "^[A-Za-z0-9][A-Za-z0-9._-]*$",
                options: .regularExpression
              ) != nil
        else { return nil }
        return trimmed
    }
}
