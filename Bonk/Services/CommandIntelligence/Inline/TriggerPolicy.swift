//  TriggerPolicy.swift
//  Bonk
//
//  Decides whether and when to trigger an LLM request for inline completion.
//  Separated cleanly from CandidateRanker (which decides candidate ordering).
//

import Foundation

/// Deterministic confidence of local candidates.
enum DeterministicConfidence: Sendable {
    /// High confidence: exact prefix match, high-frequency history, or known CLI subcommand.
    case high(candidate: Suggestion)
    /// Medium confidence: multiple fuzzy or lower-score candidates.
    case medium(candidates: [Suggestion])
    /// Low confidence: no deterministic candidate found.
    case low
}

/// Reason why LLM trigger evaluation resulted in true or false.
enum TriggerReason: String, Sendable {
    case inputTooShort = "input_too_short"
    case deterministicHighConfidence = "deterministic_high_confidence"
    case cursorInMiddleOfToken = "cursor_in_middle_of_token"
    case noDeterministicCandidate = "no_deterministic_candidate"
    case naturalLanguageIntent = "natural_language_intent"
    case explicitAIRequest = "explicit_ai_request"
    case singleCharacterRoot = "single_character_root"
    case parameterCompletion = "parameter_completion"
}

/// Tiered timing for inline completion debounce.
enum InlineTriggerTier: String, Sendable {
    case immediate = "immediate"           // 0ms (explicit Cmd+Space / selection / high confidence)
    case parameter = "parameter"           // 80ms (space transition into parameter/flag)
    case normal = "normal"                 // 120ms (multi-char typing)
    case naturalLanguage = "natural"       // 150ms (comment or CJK natural language)
    case standard = "standard"             // 220ms (unrecognized command fallback)
    case singleCharDelay = "single_char"   // 350ms (single-character root pause)
    case suppressed = "suppressed"         // 0ms (no LLM, token middle, empty)
}

/// Outcome of trigger evaluation.
struct TriggerDecision: Sendable {
    let shouldRequestLLM: Bool
    let reason: TriggerReason
    let debounceMs: Int
    let tier: InlineTriggerTier

    init(
        shouldRequestLLM: Bool,
        reason: TriggerReason,
        debounceMs: Int,
        tier: InlineTriggerTier = .standard
    ) {
        self.shouldRequestLLM = shouldRequestLLM
        self.reason = reason
        self.debounceMs = debounceMs
        self.tier = tier
    }
}

/// Evaluates trigger decisions based on input length, cursor context, token boundary, and deterministic confidence.
struct InlineTriggerPolicy: Sendable {
    static func evaluate(
        typed: String,
        snapshot: CommandContextSnapshot,
        confidence: DeterministicConfidence,
        isExplicitHotkey: Bool = false
    ) -> TriggerDecision {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)

        // 0. Explicit hotkey request (e.g. Cmd+Space) -> 0ms immediate
        if isExplicitHotkey {
            return TriggerDecision(shouldRequestLLM: true, reason: .explicitAIRequest, debounceMs: 0, tier: .immediate)
        }

        // 1. Minimum length requirement:
        // Empty buffer -> suppressed
        guard !trimmed.isEmpty else {
            return TriggerDecision(shouldRequestLLM: false, reason: .inputTooShort, debounceMs: 0, tier: .suppressed)
        }

        // 1 character root -> never request LLM, 350ms root pause tier
        guard trimmed.count >= 2 else {
            return TriggerDecision(shouldRequestLLM: false, reason: .inputTooShort, debounceMs: 350, tier: .singleCharDelay)
        }

        // 2. Cursor in middle of a token check: e.g. "che|ckout"
        if isCursorInMiddleOfToken(buffer: snapshot.inputBuffer, cursorOffset: snapshot.cursorOffset) {
            return TriggerDecision(shouldRequestLLM: false, reason: .cursorInMiddleOfToken, debounceMs: 0, tier: .suppressed)
        }

        // 3. High deterministic confidence: exact history match or known CLI spec -> no LLM!
        if case .high = confidence {
            return TriggerDecision(shouldRequestLLM: false, reason: .deterministicHighConfidence, debounceMs: 0, tier: .immediate)
        }

        // 4. Natural language intent or shell comment (e.g. starts with "#" or contains CJK prompt like "# 列出镜像")
        if trimmed.hasPrefix("#") || isNaturalLanguageIntent(trimmed) {
            return TriggerDecision(shouldRequestLLM: true, reason: .naturalLanguageIntent, debounceMs: 150, tier: .naturalLanguage)
        }

        // 5. Explicit AI request marker (e.g. triggered via user selection or explicit action)
        if snapshot.selection != nil && !snapshot.selection!.isEmpty {
            return TriggerDecision(shouldRequestLLM: true, reason: .explicitAIRequest, debounceMs: 100, tier: .immediate)
        }

        // 6. Parameter completion position: typed line ends with trailing space (e.g. "git checkout ")
        if typed.hasSuffix(" ") {
            return TriggerDecision(shouldRequestLLM: true, reason: .noDeterministicCandidate, debounceMs: 80, tier: .parameter)
        }

        // 7. No deterministic candidate or medium confidence -> allow LLM with safe standard debounce (220ms)
        return TriggerDecision(shouldRequestLLM: true, reason: .noDeterministicCandidate, debounceMs: 220, tier: .standard)
    }

    /// Checks if cursor is strictly inside a word (surrounded by non-whitespace on both sides).
    /// e.g. "che|ckout" -> true, but "git checkout |" or "git checkout|" or "git |checkout" -> false.
    static func isCursorInMiddleOfToken(buffer: String, cursorOffset: Int?) -> Bool {
        guard let pos = cursorOffset, pos > 0, pos < buffer.count else { return false }
        let idx = buffer.index(buffer.startIndex, offsetBy: pos)
        let prevIdx = buffer.index(before: idx)
        let charBefore = buffer[prevIdx]
        let charAfter = buffer[idx]
        return !charBefore.isWhitespace && !charAfter.isWhitespace
    }

    /// Heuristic for natural language intent: contains CJK characters.
    static func isNaturalLanguageIntent(_ text: String) -> Bool {
        text.contains { $0.unicodeScalars.contains { scalar in (0x4E00...0x9FFF).contains(scalar.value) } }
    }
}
