//  CommandEditor.swift
//  Bonk
//
//  Editor owns input state and cursor — Terminal cursor ≠ Editor cursor (Invariant #2).
//  Decides *when* and *what* to complete, not *how* to render.
//

import AppKit
import SwiftTerm

/// Pure decision for whether a key event should trigger completion.
enum CommandEditorTrigger: Sendable {
    case trigger
    case suppress
}

/// Editor boundary — extracts typed text and gate checks.
//  Lives in Intelligence, not in View. View provides raw terminal metrics, Editor decides.
enum CommandEditor {
    /// Whether a key event should arm the debounce (plain typing only).
    static func shouldTriggerForKey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String?
    ) -> Bool {
        guard keyCode != 53 else { return false } // Esc
        guard modifiers.isDisjoint(with: [.command, .control]) else { return false }
        if keyCode == 51 || keyCode == 117 { return true } // delete
        return !(characters?.isEmpty ?? true)
    }

    /// Pick the command text to complete: prefer pure buffer tail, else prompt stripping.
    @MainActor static func resolveTypedText(rawLine: String, inputBuffer: String) -> String? {
        let typed = inputBuffer.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, rawLine.hasSuffix(typed) { return typed }
        return SuggestionFormatter.commandText(from: rawLine)
    }

    /// Whether the cursor is at a completable position (bottom + prompt row + EOL).
    /// `isPromptRow` = semanticRowKind == .initial/.continuation when available, else nil (fallback to atBottom).
    static func isCompletable(
        cursorX: Int,
        cursorY: Int,
        rows: Int,
        yDisp: Int,
        scrollPosition: Double,
        isAlternate: Bool,
        lineTrimmedLength: Int,
        isPromptRow: Bool?
    ) -> Bool {
        guard !isAlternate else { return false }
        guard cursorY >= 0, cursorY < rows else { return false }
        let atBottom = scrollPosition >= 1.0 || yDisp == 0
        let onPromptRow = isPromptRow ?? atBottom
        guard onPromptRow else { return false }
        // Only when cursor at end of line (allow 3-char slack for wide chars)
        return cursorX >= lineTrimmedLength - 3
    }

    /// Re-align a suggestion suffix against the *current* line at accept time.
    /// The suggestion may be stale — generated for an earlier typed prefix while
    /// an LLM stream was still committing. Strips any overlap between the
    /// suggestion and the current line tail (longest line-suffix that prefixes
    /// the suggestion); returns nil when nothing would remain to insert.
    static func alignedAcceptSuffix(suggestion: String, rawLine: String) -> String? {
        guard !suggestion.isEmpty else { return nil }
        // Full command replacement with backspaces (e.g. natural language translation)
        if suggestion.hasPrefix("\u{7F}") {
            return suggestion
        }
        var overlap = 0
        let maxOverlap = min(rawLine.count, suggestion.count)
        if maxOverlap > 0 {
            for length in stride(from: maxOverlap, through: 1, by: -1)
            where rawLine.hasSuffix(String(suggestion.prefix(length))) {
                overlap = length
                break
            }
        }
        let suffix = String(suggestion.dropFirst(overlap))
        return suffix.isEmpty ? nil : suffix
    }

    /// Build snapshot for pipeline — delegates to WorkspaceContextProvider in real flow.
    /// Kept here for single place that owns typed resolution.
    @MainActor
    static func typedSnapshot(
        base: CommandContextSnapshot,
        rawLine: String
    ) -> CommandContextSnapshot? {
        guard let typed = resolveTypedText(rawLine: rawLine, inputBuffer: base.inputBuffer),
              !typed.isEmpty else { return nil }
        var snap = base
        snap.inputBuffer = typed
        return snap
    }
}
