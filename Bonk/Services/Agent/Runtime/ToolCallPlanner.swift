//
//  ToolCallPlanner.swift
//  Bonk
//
//  Decides which tool calls can run together.
//
//  The model can ask for several things in one turn. Running them one
//  after another wastes the time the user is waiting for — three
//  independent inspections take three round trips instead of one.
//
//  Not every call can go in a batch, and the reason is not "some are
//  slower". It is that a batch runs its calls **at the same time**, and
//  two things that happen at the same time can interfere.
//
//  A call joins a batch only when it is **safe to overlap**:
//
//  - it cannot change anything (a read, or a command that only
//    inspects), and
//  - it cannot ask the user anything, so two permission dialogs can
//    never appear at once.
//
//  Everything else runs alone, in the order the model asked for it.
//
//  This is the shape the reference uses: consecutive concurrency-safe
//  calls form a batch, and a call that is not safe gets a batch of its
//  own. The reference also treats a tool that cannot answer "is this
//  safe?" as unsafe, and so does this one — a conservative answer is
//  the only safe answer.
//

import Foundation

/// The plan for one assistant turn's tool calls.
enum ToolCallPlanner {

    /// One group of calls that run together.
    struct Batch: Equatable {
        /// The calls, in the order the model asked for them.
        var calls: [LLMToolCall]
        /// Whether they may run at the same time.
        let isParallel: Bool
    }

    /// How many calls may run at once.
    ///
    /// Bounded because the host has to carry them: every concurrent call
    /// is a live command channel on the connection.
    static let maxParallelCalls = 8

    /// Split the calls into batches.
    ///
    /// Pure: this is the decision, and it is worth being able to read it
    /// without a runtime, a host, or a model.
    static func batches(for calls: [LLMToolCall]) -> [Batch] {
        var batches: [Batch] = []
        for call in calls {
            let safe = isConcurrencySafe(call)
            if safe, !batches.isEmpty, batches[batches.count - 1].isParallel {
                batches[batches.count - 1].calls.append(call)
            } else {
                batches.append(Batch(calls: [call], isParallel: safe))
            }
        }
        // A batch bigger than the host can carry is split. Every
        // concurrent call is a live command channel on the connection, so
        // the number of them is the number of channels the host has to
        // hold open.
        var limited: [Batch] = []
        for batch in batches {
            guard batch.isParallel, batch.calls.count > maxParallelCalls else {
                limited.append(batch)
                continue
            }
            for start in stride(from: 0, to: batch.calls.count, by: maxParallelCalls) {
                let end = min(start + maxParallelCalls, batch.calls.count)
                limited.append(Batch(calls: Array(batch.calls[start..<end]), isParallel: true))
            }
        }
        return limited
    }

    /// May this call run at the same time as another?
    ///
    /// The test is behavioural: a call that only reads, and that the
    /// permission policy never asks about, cannot interfere with another
    /// read and cannot put two dialogs on the screen.
    static func isConcurrencySafe(_ call: LLMToolCall) -> Bool {
        switch call.name {
        case ReadFileTool.toolName,
             SearchHistoryTool.toolName,
             InspectSystemTool.toolName,
             ListDirectoryTool.toolName,
             SkillTool.toolName:
            // Pure reads of the app's own state or of the host's files.
            // The permission policy allows every one of them outright, in
            // every access mode, so they never ask.
            return true
        case BashRunTool.toolName:
            // A command that only inspects changes nothing and is never
            // worth a dialog. Anything that mutates, or that is risky
            // enough to ask about, runs alone.
            guard let command = commandArgument(call) else { return false }
            return CommandSafety.classifyLevel(command) <= .l1SafeInspection
        default:
            // A tool nobody has classified: assume it is not safe.
            return false
        }
    }

    /// The command a call would run, if it is a command call.
    static func commandArgument(_ call: LLMToolCall) -> String? {
        guard let arguments = Self.decodeArguments(call.argumentsJSON) else { return nil }
        return arguments["command"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The arguments of a call, decoded.
    ///
    /// A call whose arguments do not parse is treated as having no
    /// arguments — which for a command means "not safe to overlap".
    static func decodeArguments(_ json: String) -> [String: String]? {
        guard let data = json.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let text = value as? String {
                result[key] = text
            } else if let number = value as? NSNumber {
                result[key] = number.stringValue
            } else if let bool = value as? Bool {
                result[key] = bool ? "true" : "false"
            } else {
                // A structured argument: keep its JSON form, so a command
                // that was passed one is not silently read as absent.
                if let encoded = try? JSONSerialization.data(withJSONObject: value),
                   let text = String(data: encoded, encoding: .utf8) {
                    result[key] = text
                }
            }
        }
        return result
    }
}
