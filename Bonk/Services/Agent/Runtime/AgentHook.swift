//
//  AgentHook.swift
//  Bonk
//
//  Hooks let plugins observe and influence the agent loop without
//  touching the runtime's internals. A hook is a small, focused callback
//  that runs at a well-defined point: before a tool is called, or after
//  it returns.
//
//  Hooks are the extension point for plugins: a plugin registers a hook,
//  and the runtime calls it at the right moment. Hooks run in registration
//  order, and each hook sees the result of the previous one.
//
//  A hook must never block for long: it runs on the agent loop's task, so
//  a slow hook stalls the whole run. Hooks that need network or disk access
//  should do it with a timeout and degrade gracefully.
//

import Foundation

/// A hook into the agent loop.
///
/// Implement this to observe or influence tool execution. A plugin
/// registers its hook with `AgentHookRegistry`, and the runtime calls it
/// at the right moment.
///
/// Hooks run in registration order. `willCallTool` sees the arguments
/// before they reach the tool; `didCallTool` sees the output before it
/// reaches the model. Each hook can transform what it sees, and the next
/// hook sees the transformed result.
protocol AgentHook: Sendable, AnyObject {
    /// The hook's name, for debugging and dedup.
    var name: String { get }

    /// Called before a tool is executed.
    ///
    /// Return the arguments to use, or `nil` to block the call entirely.
    /// Returning `nil` means the tool never runs and the model is told
    /// the call was blocked by a hook.
    func willCallTool(toolName: String, arguments: [String: String]) async -> [String: String]?

    /// Called after a tool returns.
    ///
    /// Return the output to give the model, or `output` unchanged to let
    /// it through.
    func didCallTool(toolName: String, arguments: [String: String], output: String, exitCode: Int32) async -> String
}

/// A registry of hooks, run in registration order.
final class AgentHookRegistry: @unchecked Sendable {
    private var hooks: [any AgentHook] = []
    private let lock = NSLock()

    /// Register a hook. Hooks run in the order they are registered.
    func register(_ hook: any AgentHook) {
        lock.lock()
        hooks.append(hook)
        lock.unlock()
    }

    /// All registered hooks, in registration order.
    var all: [any AgentHook] {
        lock.lock()
        defer { lock.unlock() }
        return hooks
    }

    /// Call `willCallTool` on every hook in order. Return the (possibly
    /// transformed) arguments, or `nil` if any hook blocked the call.
    func willCallTool(toolName: String, arguments: [String: String]) async -> [String: String]? {
        var arguments = arguments
        for hook in all {
            guard let next = await hook.willCallTool(toolName: toolName, arguments: arguments) else {
                return nil
            }
            arguments = next
        }
        return arguments
    }

    /// Call `didCallTool` on every hook in order. Return the (possibly
    /// transformed) output.
    func didCallTool(toolName: String, arguments: [String: String], output: String, exitCode: Int32) async -> String {
        var output = output
        for hook in all {
            output = await hook.didCallTool(toolName: toolName, arguments: arguments, output: output, exitCode: exitCode)
        }
        return output
    }
}
