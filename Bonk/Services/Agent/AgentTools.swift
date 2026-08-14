import Foundation

/// Tool definitions and response models for the agentic tool loop.
enum AgentTools {
    static let runCommandName = "run_command"

    /// OpenAI-compatible function-calling schema. Computed per call so the
    /// dictionary never crosses actor boundaries as shared state.
    static var definitions: [[String: Any]] {
        [
            [
                "type": "function",
                "function": [
                    "name": runCommandName,
                    "description": """
                    Run a single shell command on the connected remote server and return \
                    its output. Use this for any task that needs to inspect or change the \
                    remote system. Inspect before acting: ls, pwd, cat, df, ps first.
                    """,
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "command": [
                                "type": "string",
                                "description": "The exact shell command to execute. One command per call.",
                            ],
                        ],
                        "required": ["command"],
                    ],
                ],
            ],
        ]
    }

}

/// One function call requested by the model.
struct AgentToolCall {
    let id: String
    let name: String
    let arguments: [String: Any]
    let argumentsJSON: String
}

/// One chat-completions turn from the model.
struct AgentChatTurn {
    let content: String?
    let toolCalls: [AgentToolCall]
}
