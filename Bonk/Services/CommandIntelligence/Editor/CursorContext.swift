//  CursorContext.swift
//  Bonk
//
//  Minimal cursor position for the inline-suggestion invariant:
//  ghost renders only at line end; accept verifies the anchor.
//  Deliberately NOT an editor model — no token math, no coordinate mapping.
//  Anything fancier (mid-line recompute, cell geometry) was cut on purpose:
//  the terminal owns editing, AI only assists at end of line.

import Foundation

/// Cursor position resolved against the typed buffer.
struct CursorContext: Sendable, Equatable {
    /// Cursor offset in characters inside the typed buffer, if known.
    /// nil = unknown (legacy path); treated as at-end for trigger parity,
    /// but accept defense requires a known offset to pass.
    let offset: Int?
    /// Resolved end-of-line state. Ghost renders only when true.
    let isAtLineEnd: Bool

    /// True only when the offset was explicitly provided (not assumed).
    var isCursorKnown: Bool {
        offset != nil
    }

    /// Builds from a typed buffer and an optional cursor offset.
    /// Out-of-range offsets clamp to line end.
    static func resolve(buffer: String, cursorOffset: Int?) -> CursorContext {
        guard let offset = cursorOffset else {
            return CursorContext(offset: nil, isAtLineEnd: true)
        }
        let clamped = max(0, min(offset, buffer.count))
        return CursorContext(offset: clamped, isAtLineEnd: clamped >= buffer.count)
    }

    /// Anchor check for accept: the suggestion computed for `anchorBuffer`
    /// may be inserted into `currentBuffer` only when the user merely
    /// appended at end (no mid-line edits, no deletions of the anchor).
    /// This is the async-staleness guard (t0 request, t1 typing, t2 accept).
    static func anchorAllowsInsert(anchorBuffer: String, currentBuffer: String) -> Bool {
        currentBuffer.hasPrefix(anchorBuffer)
    }
}
