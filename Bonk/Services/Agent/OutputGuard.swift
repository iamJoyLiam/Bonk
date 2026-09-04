//  OutputGuard.swift
//  Bonk
//
//  Output safety budget guard for terminal execution in Agent mode.
//  Protects LLM context window & UI from flooding via Head 80 + Tail 80 + 32KB budget.
//

import Foundation

struct OutputGuardResult: Sendable, Equatable {
    let content: String
    let totalLines: Int
    let totalBytes: Int
    let isTruncated: Bool
    let skippedLines: Int
    let skippedBytes: Int
}

struct OutputGuard: Sendable {
    static let maxHeadLines = 80
    static let maxTailLines = 80
    static let maxBytes = 32 * 1024 // 32 KB

    /// Guards raw command output by applying head+tail line limits and total byte budget.
    static func guardOutput(_ raw: String) -> OutputGuardResult {
        let totalBytes = raw.utf8.count
        let lines = raw.components(separatedBy: "\n")
        let totalLines = lines.count

        // If within budget, return raw text directly
        if totalBytes <= maxBytes && totalLines <= (maxHeadLines + maxTailLines) {
            return OutputGuardResult(
                content: raw,
                totalLines: totalLines,
                totalBytes: totalBytes,
                isTruncated: false,
                skippedLines: 0,
                skippedBytes: 0
            )
        }

        // Truncate by Head 80 and Tail 80 lines
        let headCount = min(maxHeadLines, totalLines)
        let headLines = Array(lines.prefix(headCount))
        
        let remainingAfterHead = max(0, totalLines - headCount)
        let tailCount = min(maxTailLines, remainingAfterHead)
        let tailLines = Array(lines.suffix(tailCount))

        let skippedLines = totalLines - headLines.count - tailLines.count

        let headText = headLines.joined(separator: "\n")
        let tailText = tailLines.joined(separator: "\n")

        var skippedBytes = max(0, totalBytes - headText.utf8.count - tailText.utf8.count)

        let truncationMarker = "\n... [Output truncated: \(skippedLines) lines skipped (\(skippedBytes) bytes)] ...\n"
        var combined = headText + truncationMarker + tailText

        // If still exceeds byte budget (e.g. very long individual lines), hard truncate to maxBytes
        if combined.utf8.count > maxBytes {
            let prefixBudget = maxBytes / 2
            let suffixBudget = maxBytes / 2
            let headSlice = String(combined.prefix(prefixBudget))
            let tailSlice = String(combined.suffix(suffixBudget))
            combined = headSlice + "\n... [Output truncated to 32KB budget] ...\n" + tailSlice
            skippedBytes = max(skippedBytes, totalBytes - combined.utf8.count)
        }

        return OutputGuardResult(
            content: combined,
            totalLines: totalLines,
            totalBytes: totalBytes,
            isTruncated: true,
            skippedLines: skippedLines,
            skippedBytes: skippedBytes
        )
    }
}
