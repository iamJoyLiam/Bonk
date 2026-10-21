//
//  AgentTodoToolTests.swift
//  BonkTests
//
//  The task list the model keeps for itself.
//
//  The defect this closes (P1-8): `AgentState.progress` counted the steps
//  that ran, but the model never saw them. It knew what it had asked for
//  and what had come back, and had to infer where it was from that.
//
//  The tool has to survive three things:
//
//  1. The model writes it, so the payload can be anything.
//  2. The tool's argument is structured, and the runtime's argument
//     conversion used to flatten it into a Swift description — which is not
//     JSON and cannot be parsed back.
//  3. It must not cost the user a confirmation prompt: it runs nothing.
//

import Foundation
import os
import Testing
@testable import Bonk

@Suite("Agent task list")
struct AgentTodoToolTests {

    // MARK: - Parsing

    @Test("A list the model wrote is read back")
    func aListIsParsed() {
        let raw = """
        [{"content":"Check disk usage","status":"pending","activeForm":"Checking disk usage"},
         {"content":"Restart the service","status":"in_progress"}]
        """
        let items = TodoWriteTool.parse(raw)
        #expect(items?.count == 2)
        #expect(items?.first?.content == "Check disk usage")
        #expect(items?.first?.status == .pending)
        #expect(items?.first?.activeForm == "Checking disk usage")
        #expect(items?.last?.status == .inProgress)
        #expect(items?.last?.activeForm == nil)
    }

    @Test("A status the model spelled its own way is understood")
    func statusSpellingsAreUnderstood() {
        #expect(AgentTodoItem.Status(modelText: "in_progress") == .inProgress)
        #expect(AgentTodoItem.Status(modelText: "inprogress") == .inProgress)
        #expect(AgentTodoItem.Status(modelText: "In Progress") == .inProgress)
        #expect(AgentTodoItem.Status(modelText: "complete") == .completed)
        #expect(AgentTodoItem.Status(modelText: "done") == .completed)
        #expect(AgentTodoItem.Status(modelText: "pending") == .pending)
    }

    @Test("A malformed list is reported, not accepted")
    func malformedListsAreRejected() {
        // Not an array.
        #expect(TodoWriteTool.parse("{\"content\":\"x\"}") == nil)
        // Not JSON.
        #expect(TodoWriteTool.parse("not json") == nil)
        // An item with no content.
        #expect(TodoWriteTool.parse(#"[{"status":"pending"}]"#) == nil)
        // An item whose content is blank.
        #expect(TodoWriteTool.parse(#"[{"content":"   ","status":"pending"}]"#) == nil)
        // An item with no status.
        #expect(TodoWriteTool.parse(#"[{"content":"x"}]"#) == nil)
    }

    @Test("An empty list is a valid list")
    func anEmptyListIsValid() {
        #expect(TodoWriteTool.parse("[]")?.isEmpty == true)
    }

    @Test("The list reads back with its states marked")
    func theListRenders() {
        let items = [
            AgentTodoItem(content: "One", status: .completed),
            AgentTodoItem(content: "Two", status: .inProgress),
            AgentTodoItem(content: "Three", status: .pending)
        ]
        let rendered = TodoWriteTool.render(items)
        #expect(rendered.contains("[x] One"))
        #expect(rendered.contains("[~] Two"))
        #expect(rendered.contains("[ ] Three"))
        #expect(TodoWriteTool.render([]) == "Task list cleared.")
    }

    // MARK: - The store

    @Test("The store holds the list the model wrote")
    func theStoreHoldsTheList() async throws {
        let store = AgentTodoStore()
        let tool = TodoWriteTool(store: store)
        let result = try await tool.execute(
            id: "call-1",
            arguments: ["todos": #"[{"content":"One","status":"pending"}]"#],
            executionManager: AgentExecutionManager(),
            executor: { _, _ in ("", 0) }
        )
        #expect(result.exitCode == 0)
        let items = await store.items
        #expect(items.count == 1)
        #expect(items.first?.content == "One")
    }

    @Test("A malformed list leaves the previous list alone")
    func aMalformedListChangesNothing() async throws {
        let store = AgentTodoStore()
        let tool = TodoWriteTool(store: store)
        _ = try await tool.execute(
            id: "call-1",
            arguments: ["todos": #"[{"content":"One","status":"pending"}]"#],
            executionManager: AgentExecutionManager(),
            executor: { _, _ in ("", 0) }
        )
        let result = try await tool.execute(
            id: "call-2",
            arguments: ["todos": "not json"],
            executionManager: AgentExecutionManager(),
            executor: { _, _ in ("", 0) }
        )
        #expect(result.exitCode == 1, "a malformed list must be reported")
        let items = await store.items
        #expect(items.count == 1, "the previous list must survive a malformed write")
    }

    // MARK: - Permission

    @Test("The task list never costs a confirmation")
    func theTaskListNeverAsks() {
        let policy = DefaultAgentPermissionPolicy(accessMode: .supervised)
        let decision = policy.evaluate(
            tool: TodoWriteTool.toolName,
            arguments: ["todos": "[]"]
        )
        if case .allowed = decision {
            // expected
        } else {
            Issue.record("the task list must not ask the user for permission")
        }
    }

    // MARK: - The runtime


    /// Drive a run to completion.
    ///
    /// Any permission the run asks for is approved on the spot. A test that
    /// hangs when the policy changes is a test that cannot report the
    /// change — the run has to finish either way, and the asking is what
    /// gets asserted.
    private func drive(
        _ runtime: AgentRuntime,
        input: String = "check the disk and restart the service"
    ) async -> (published: [AgentTodoItem], askedForPermission: Bool) {
        var published: [AgentTodoItem] = []
        var asked = false
        for await event in runtime.run(input: input) { _, _ in ("ok", 0) } {
            switch event {
            case let .todoListUpdated(items):
                published = items
            case let .permissionRequested(id, _, _, _):
                asked = true
                runtime.resolvePermission(id: id, approved: true)
            default:
                break
            }
            if case .completed = event { break }
        }
        return (published, asked)
    }

    /// A gateway that calls the task list tool on its first turn, then
    /// answers.
    final class TodoCallingGateway: AgentModelGateway, @unchecked Sendable {
        private let turn = OSAllocatedUnfairLock<Int>(uncheckedState: 0)
        private let requests = OSAllocatedUnfairLock<[[LLMMessage]]>(uncheckedState: [])
        var captured: [[LLMMessage]] { requests.withLock { $0 } }

        func chat(messages: [LLMMessage], tools: [LLMToolDefinition]) async throws -> LLMResponse {
            requests.withLock { $0.append(messages) }
            let index = turn.withLock { current -> Int in
                defer { current += 1 }
                return current
            }
            guard index == 0 else { return LLMResponse(text: "All done.") }
            // The todos are an ARRAY in the call, not a string: a tool whose
            // arguments are structured has to receive them intact.
            return LLMResponse(text: "", toolCalls: [
                LLMToolCall(
                    id: "call-1",
                    name: TodoWriteTool.toolName,
                    argumentsJSON: """
                    {"todos":[{"content":"Check disk usage","status":"in_progress",\
                    "activeForm":"Checking disk usage"},\
                    {"content":"Restart the service","status":"pending"}]}
                    """
                )
            ])
        }

        func streamTurn(
            messages: [LLMMessage],
            tools: [LLMToolDefinition]
        ) -> AsyncThrowingStream<LLMStreamEvent, Error>? {
            nil
        }
    }

    @Test("The list the model wrote reaches the user")
    func theListReachesTheUser() async {
        let gateway = TodoCallingGateway()
        let registry = AgentToolRegistry()
        let runtime = AgentRuntime(
            modelGateway: gateway,
            toolRegistry: registry,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised)
        )

        let (published, _) = await drive(runtime)

        #expect(published.count == 2, "the list the model wrote must reach the user")
        #expect(published.first?.content == "Check disk usage")
        #expect(published.first?.status == .inProgress)
        #expect(published.first?.activeForm == "Checking disk usage")
        #expect(published.last?.status == .pending)
    }

    @Test("The list the model wrote is what the agent is working from")
    func theListIsStored() async {
        let gateway = TodoCallingGateway()
        let registry = AgentToolRegistry()
        let runtime = AgentRuntime(
            modelGateway: gateway,
            toolRegistry: registry,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised)
        )
        _ = await drive(runtime)
        let items = await registry.todoStore.items
        #expect(items.count == 2)
        #expect(items.first?.content == "Check disk usage")
    }

    @Test("The model sees its own list back")
    func theModelSeesItsList() async {
        let gateway = TodoCallingGateway()
        let registry = AgentToolRegistry()
        let runtime = AgentRuntime(
            modelGateway: gateway,
            toolRegistry: registry,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised)
        )
        _ = await drive(runtime)
        let requests = gateway.captured
        #expect(requests.count >= 2, "the loop must have come back for another turn")
        let toolResult = requests.last?.first { $0.role == .tool }
        #expect(toolResult?.content.contains("Check disk usage") == true,
                "the model must get its list back, not just a confirmation")
    }

    @Test("The tool never asks the user")
    func theToolNeverAsks() async {
        let gateway = TodoCallingGateway()
        let registry = AgentToolRegistry()
        let runtime = AgentRuntime(
            modelGateway: gateway,
            toolRegistry: registry,
            permissionPolicy: DefaultAgentPermissionPolicy(accessMode: .supervised)
        )
        let (_, asked) = await drive(runtime)
        #expect(!asked, "the task list runs nothing, so it must not ask for permission")
    }
}
