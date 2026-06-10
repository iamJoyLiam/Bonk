import Foundation
import os.log

/// Loads custom instructions from project-level configuration files.
/// Similar to `.github/copilot-instructions.md` for GitHub Copilot.
enum CustomInstructions {
    private static let logger = Logger(subsystem: "com.bonk", category: "CustomInstructions")

    /// File names to search for custom instructions (in priority order).
    private static let instructionFiles = [
        ".bonk/instructions.md",
        ".bonk/instructions.txt",
        ".ai-instructions.md",
        "AI_INSTRUCTIONS.md",
    ]

    /// Load custom instructions from the current working directory.
    /// Returns the combined instructions text, or nil if no instructions found.
    static func load(from directory: String? = nil) -> String? {
        let cwd = directory ?? FileManager.default.currentDirectoryPath
        var instructions: [String] = []

        for fileName in instructionFiles {
            let path = (cwd as NSString).appendingPathComponent(fileName)
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    instructions.append(trimmed)
                    logger.info("Loaded instructions from \(fileName, privacy: .public)")
                }
            }
        }

        guard !instructions.isEmpty else { return nil }
        return instructions.joined(separator: "\n\n---\n\n")
    }

    /// Build a system prompt with custom instructions injected.
    static func buildSystemPrompt(base: String, directory: String? = nil) -> String {
        guard let custom = load(from: directory) else { return base }
        return """
        \(base)

        ## Project-Specific Instructions
        The following instructions are from the project configuration.
        They take priority over general guidelines:

        \(custom)
        """
    }
}
