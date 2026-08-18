//
//  SSHKeyboardInteractiveAuth.swift
//  Bonk
//
//  OpenSSH keyboard-interactive prompt UI.
//

import Foundation
#if os(macOS)
import AppKit
#endif

enum SSHKeyboardInteractivePromptError: LocalizedError {
    case cancelled
    case unsupportedPlatform

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "Keyboard-interactive authentication cancelled."
        case .unsupportedPlatform:
            "Keyboard-interactive authentication is unavailable on this platform."
        }
    }
}

enum SSHKeyboardInteractivePromptController {
    /// Prompt provider for OpenSSH PTY-backed commands.
    static func promptText(
        name: String,
        instruction: String,
        prompts: [(label: String, echo: Bool)]
    ) async throws -> [String] {
        #if os(macOS)
            return try await MainActor.run {
                try showTextPrompt(
                    name: name,
                    instruction: instruction,
                    prompts: prompts
                )
            }
        #else
            throw SSHKeyboardInteractivePromptError.unsupportedPlatform
        #endif
    }

    #if os(macOS)
        @MainActor
        private static func showTextPrompt(
            name: String,
            instruction: String,
            prompts: [(label: String, echo: Bool)]
        ) throws -> [String] {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = name.isEmpty ? "SSH authentication required" : name
            alert.informativeText = instruction.isEmpty
                ? "Enter requested verification information."
                : instruction
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")

            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false

            var fields: [NSTextField] = []
            for item in prompts {
                let label = NSTextField(labelWithString: item.label)
                label.alignment = .left

                let field: NSTextField = item.echo
                    ? NSTextField()
                    : NSSecureTextField()
                field.placeholderString = item.label
                field.translatesAutoresizingMaskIntoConstraints = false
                field.widthAnchor.constraint(equalToConstant: 300).isActive = true

                stack.addArrangedSubview(label)
                stack.addArrangedSubview(field)
                fields.append(field)
            }

            let height = max(CGFloat(prompts.count * 52), 44)
            stack.frame = NSRect(x: 0, y: 0, width: 300, height: height)
            alert.accessoryView = stack

            guard alert.runModal() == .alertFirstButtonReturn else {
                throw SSHKeyboardInteractivePromptError.cancelled
            }
            return fields.map(\.stringValue)
        }
    #endif
}
