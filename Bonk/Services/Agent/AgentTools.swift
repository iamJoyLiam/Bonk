import Foundation

/// Tool definitions and response models for the agentic tool loop.
enum AgentTools {
    static let runCommandName = "run_command"

    /// Provider-agnostic function-calling schema. Adapters translate it into
    /// each wire format (chat-completions `tools`, Responses API `tools`).
    static var definitions: [LLMToolDefinition] {
        [
            LLMToolDefinition(
                name: runCommandName,
                description: """
                Run a single shell command on the connected remote server and return \
                its output. Use this for any task that needs to inspect or change the \
                remote system. Inspect before acting: ls, pwd, cat, df, ps first.
                """,
                parametersJSON: """
                {
                  "type": "object",
                  "properties": {
                    "command": {
                      "type": "string",
                      "description": "The exact shell command to execute. One command per call."
                    }
                  },
                  "required": ["command"]
                }
                """
            ),
        ]
    }
}
