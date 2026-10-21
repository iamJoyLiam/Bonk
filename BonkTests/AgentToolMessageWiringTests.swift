//
//  AgentToolMessageWiringTests.swift
//  BonkTests — architectural guard for the untrusted-output boundary.
//
//  ToolOutputEnvelopeTests covers the envelope itself. It cannot cover whether
//  the agent loop actually routes command output through it: injecting the
//  original bug — feeding `call.output` straight into the tool message — leaves
//  every envelope test green. That was verified by deliberately reintroducing
//  the bug and watching this suite's absence go unnoticed, so the invariant is
//  now stated over the source instead.
//
//  A tool result is the only channel through which remote-controlled text
//  reaches the model, so the rule is simple: nothing constructs
//  `LLMMessage(role: .tool)` directly — every tool message goes through
//  ToolMessage, which applies the trust class at construction time.
//

import Testing
import Foundation
@testable import Bonk

@Suite("Agent Tool Message Wiring Tests")
struct AgentToolMessageWiringTests {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BonkTests
            .deletingLastPathComponent() // repo root
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("No agent file constructs a tool message directly")
    func toolMessagesGoThroughFactory() throws {
        let files = [
            "Bonk/Services/Agent/Runtime/AgentRuntime.swift",
            "Bonk/Services/Agent/AgentToolExecutor.swift",
        ]
        var offenders: [String] = []
        for file in files {
            let src = try source(file)
            for (index, line) in src.components(separatedBy: "\n").enumerated()
            where line.contains("LLMMessage(role: .tool") {
                offenders.append("\(file):\(index + 1)  \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offenders.isEmpty,
                "tool messages must be built via ToolMessage:\n\(offenders.joined(separator: "\n"))")
    }

    @Test("Remote-derived output always uses the untrusted factory")
    func remoteOutputUsesUntrusted() throws {
        let runtime = try source("Bonk/Services/Agent/Runtime/AgentRuntime.swift")
        #expect(runtime.contains("ToolMessage.untrusted(output: call.output"))

        // And the agent has exactly one place that turns a tool result into a
        // message. A second implementation — even an unreachable one — is a
        // hazard: it carries its own trust handling, and it is not the code
        // the rest of this suite exercises. There was one: the legacy tool
        // loop had no callers, so nothing tested it, and it still carried
        // its own copy of the safety pipeline and its own trust decisions.
        //
        // This replaces a check that named one file and one string in it.
        // That check could only ever pass or fail on code that never ran;
        // this one holds for any file that grows a tool message later.
        var offenders: [String] = []
        for relative in agentSourceFiles() where relative != "Runtime/AgentRuntime.swift" {
            let src = try source("Bonk/Services/Agent/\(relative)")
            if src.contains("ToolMessage.") {
                offenders.append(relative)
            }
        }
        #expect(offenders.isEmpty,
                "only the runtime may build tool messages; these files do too: \(offenders)")
    }

    /// Every Swift file under `Bonk/Services/Agent`, relative to that folder.
    private func agentSourceFiles() -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BonkTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Bonk/Services/Agent")
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var files: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            files.append(relative)
        }
        return files
    }

    @Test("Our own policy messages use the local factory, not the envelope")
    func policyMessagesUseLocal() throws {
        let runtime = try source("Bonk/Services/Agent/Runtime/AgentRuntime.swift")
        // A refusal is our own verdict; labelling it untrusted would teach the
        // model to discount the app's own policy.
        #expect(runtime.contains("ToolMessage.local(\"Blocked by safety policy:"))
        #expect(!runtime.contains("ToolMessage.untrusted(output: \"Blocked by safety policy"))
    }

    @Test("Compaction shortens messages without stranding an open envelope")
    func compactionKeepsEnvelopeClosed() {
        // The runtime's budget is 200 characters, smaller than the verbose
        // header alone, so the compact form must be used.
        let wrapped = ToolOutputEnvelope.wrap(String(repeating: "x", count: 5_000))
        let shrunk = ToolOutputEnvelope.truncate(wrapped, to: 200)
        #expect(shrunk.contains(ToolOutputEnvelope.endMarker),
                "closing marker lost — the untrusted region would stay open")
        #expect(shrunk.count <= 200, "truncation exceeded its budget: \(shrunk.count)")
        #expect(shrunk.contains("UNTRUSTED TOOL OUTPUT"))
    }

    @Test("Compaction keeps the boundary at every budget size")
    func compactionIsSafeAtAnyBudget() {
        let wrapped = ToolOutputEnvelope.wrap(String(repeating: "y", count: 3_000))
        for limit in [40, 80, 120, 200, 400, 1_000] {
            let shrunk = ToolOutputEnvelope.truncate(wrapped, to: limit)
            // Closure is the invariant at every size.
            #expect(shrunk.contains(ToolOutputEnvelope.endMarker),
                    "budget \(limit) lost the closing marker")
            // The budget is honoured whenever a closed envelope can fit; below
            // that floor, closure deliberately wins over the byte target.
            let effective = max(limit, ToolOutputEnvelope.minimumEnvelopeSize)
            #expect(shrunk.count <= effective,
                    "budget \(limit) produced \(shrunk.count) chars")
        }
    }

    @Test("Compaction of a local message is a plain prefix")
    func compactionOfLocalMessageIsPlainPrefix() {
        let local = String(repeating: "y", count: 500)
        let shrunk = ToolOutputEnvelope.truncate(local, to: 100)
        #expect(shrunk == String(local.prefix(100)))
    }
}
