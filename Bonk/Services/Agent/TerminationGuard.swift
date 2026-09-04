//  TerminationGuard.swift
//  Bonk
//
//  Progress guard & loop termination policy for Agent tool execution (P1.4).
//  Detects repetitive tool invocations and fingerprint loops (NO_PROGRESS) to prevent spinning.
//

import Foundation

struct StepFingerprint: Hashable, Sendable {
    let toolName: String
    let arguments: String
    let outputHash: Int
}

@MainActor
final class TerminationGuard {
    private var fingerprints: [StepFingerprint] = []
    private var consecutiveDuplicates = 0
    private static let maxConsecutiveDuplicates = 2

    enum ProgressEvaluation: Sendable, Equatable {
        case proceed
        case warnDuplicate(toolName: String)
        case terminateLoop(reason: String)
    }

    /// Records tool step and evaluates whether progress is being made.
    func recordAndEvaluate(toolName: String, arguments: String, output: String) -> ProgressEvaluation {
        let outputHash = output.hashValue
        let current = StepFingerprint(toolName: toolName, arguments: arguments, outputHash: outputHash)

        // Check if identical tool + args + output was executed consecutively
        if let previous = fingerprints.last, previous == current {
            consecutiveDuplicates += 1
            if consecutiveDuplicates >= Self.maxConsecutiveDuplicates {
                return .terminateLoop(
                    reason: "检测到重复执行相同操作（'\(toolName)'）且无新输出，已自动终止工具循环以防陷入死循环。"
                )
            }
            return .warnDuplicate(toolName: toolName)
        }

        // Check if same command failed or repeated 3 times across the entire session
        let matchingCount = fingerprints.filter { $0.toolName == toolName && $0.arguments == arguments }.count
        if matchingCount >= 2 {
            return .terminateLoop(
                reason: "操作 '\(toolName)' 已重复执行多次无新进展，终止工具循环以输出已有结果。"
            )
        }

        fingerprints.append(current)
        consecutiveDuplicates = 0
        return .proceed
    }

    func reset() {
        fingerprints.removeAll()
        consecutiveDuplicates = 0
    }
}
