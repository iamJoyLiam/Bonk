//
//  AgentHookTests.swift
//  BonkTests
//
//  Tests for AgentHook and AgentHookRegistry - the extension point for
//  plugins to observe and influence the agent loop.
//

import Foundation
import os
import Testing
@testable import Bonk

@Suite("Agent Hook")
struct AgentHookTests {

    // MARK: - Hook registry registration

    @Test("Hooks are called in registration order")
    func hooksRunInRegistrationOrder() async {
        let registry = AgentHookRegistry()
        var order: [String] = []

        registry.register(HookSpy(name: "first", value: "a"))
        registry.register(HookSpy(name: "second", value: "b"))
        registry.register(HookSpy(name: "third", value: "c"))

        let result = await registry.willCallTool(toolName: "run_command", arguments: ["command": "echo hi"])
        #expect(result == ["command": "echo hi", "hook:first": "a", "hook:second": "b", "hook:third": "c"])
        #expect(registry.all.map(\.name) == ["first", "second", "third"])
    }

    @Test("Will call hook can block by returning nil")
    func willCallToolCanBlock() async {
        let registry = AgentHookRegistry()
        registry.register(BlockingHook(name: "blocker"))

        let result = await registry.willCallTool(toolName: "run_command", arguments: ["command": "echo hi"])
        #expect(result == nil)
    }

    @Test("Did call hook transforms output")
    func didCallToolTransformsOutput() async {
        let registry = AgentHookRegistry()
        registry.register(PrefixHook(name: "prefixer", prefix: "[HOOKED] "))

        let result = await registry.didCallTool(
            toolName: "run_command",
            arguments: ["command": "echo hi"],
            output: "original output",
            exitCode: 0
        )
        #expect(result == "[HOOKED] original output")
    }

    @Test("Multiple hooks chain transformations")
    func multipleHooksChainTransformations() async {
        let registry = AgentHookRegistry()
        registry.register(HookSpy(name: "upper", value: "UPPER:"))
        registry.register(HookSpy(name: "suffix", value: " [END]"))

        let result = await registry.didCallTool(
            toolName: "run_command",
            arguments: ["command": "echo hi"],
            output: "middle",
            exitCode: 0
        )
        #expect(result == "middle [UPPER:] [ [END]]")
    }

    // MARK: - Hook protocol conformance

    @Test("Hook name is returned correctly")
    func hookNameIsReturned() {
        let hook = TestHook(name: "test-hook")
        #expect(hook.name == "test-hook")
    }

    // MARK: - Test hooks

    /// A hook that records its name and returns a fixed value.
    final class HookSpy: AgentHook {
        let name: String
        let value: String

        init(name: String, value: String) {
            self.name = name
            self.value = value
        }

        func willCallTool(toolName: String, arguments: [String: String]) async -> [String: String]? {
            return arguments.merging(["hook:\(name)": value]) { _, new in new }
        }

        func didCallTool(toolName: String, arguments: [String: String], output: String, exitCode: Int32) async -> String {
            return "\(output) [\(value)]"
        }
    }

    /// A hook that always blocks by returning nil from willCallTool.
    final class BlockingHook: AgentHook {
        let name: String

        init(name: String) {
            self.name = name
        }

        func willCallTool(toolName: String, arguments: [String: String]) async -> [String: String]? {
            return nil
        }

        func didCallTool(toolName: String, arguments: [String: String], output: String, exitCode: Int32) async -> String {
            return output
        }
    }

    /// A hook that prefixes output.
    final class PrefixHook: AgentHook {
        let name: String
        let prefix: String

        init(name: String, prefix: String) {
            self.name = name
            self.prefix = prefix
        }

        func willCallTool(toolName: String, arguments: [String: String]) async -> [String: String]? {
            return arguments
        }

        func didCallTool(toolName: String, arguments: [String: String], output: String, exitCode: Int32) async -> String {
            return "\(prefix)\(output)"
        }
    }

    /// A basic test hook.
    final class TestHook: AgentHook {
        let name: String

        init(name: String) {
            self.name = name
        }

        func willCallTool(toolName: String, arguments: [String: String]) async -> [String: String]? {
            return arguments
        }

        func didCallTool(toolName: String, arguments: [String: String], output: String, exitCode: Int32) async -> String {
            return output
        }
    }
}
