//
//  AgentCancellationContractTests.swift
//  BonkTests
//
//  P0.2 Agent Hard Cancellation & Execution Manager Contract Tests.
//

import Testing
import Foundation
import os
@testable import Bonk

@Suite("P0.2 Agent Hard Cancellation Contract Tests")
struct AgentCancellationContractTests {

    final class MockExecutionHandle: CommandExecutionHandle, @unchecked Sendable {
        private let state = OSAllocatedUnfairLock<(interrupt: Int, terminate: Int, close: Int, events: [String])>(
            uncheckedState: (0, 0, 0, [])
        )

        var interruptCount: Int { state.withLock { $0.interrupt } }
        var terminateCount: Int { state.withLock { $0.terminate } }
        var closeCount: Int { state.withLock { $0.close } }
        var events: [String] { state.withLock { $0.events } }

        func interrupt() async throws {
            state.withLock {
                $0.interrupt += 1
                $0.events.append("interrupt")
            }
        }

        func terminate() async throws {
            state.withLock {
                $0.terminate += 1
                $0.events.append("terminate")
            }
        }

        func close() async {
            state.withLock {
                $0.close += 1
                $0.events.append("close")
            }
        }
    }

    @Test("1. Handle registration and clearing in AgentExecutionManager")
    func testHandleRegistrationAndClearing() async {
        let manager = AgentExecutionManager()
        let handle = MockExecutionHandle()

        let initial = await manager.hasActiveHandle
        #expect(!initial)

        await manager.registerActive(handle)
        let active = await manager.hasActiveHandle
        #expect(active)

        await manager.clearActive()
        let cleared = await manager.hasActiveHandle
        #expect(!cleared)
    }

    @Test("2. Cancellation immediately triggers Level 1 interrupt (SIGINT / 0x03)")
    func testCancellationDispatchesInterruptFirst() async {
        let manager = AgentExecutionManager()
        let handle = MockExecutionHandle()

        await manager.registerActive(handle)

        let cancelTask = Task {
            await manager.cancelActive()
        }

        // Within 50ms (before 300ms grace period expires), interrupt must have been called
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(handle.interruptCount == 1)
        #expect(handle.terminateCount == 0)
        #expect(handle.closeCount == 0)

        await cancelTask.value
    }

    @Test("3. Full cancellation escalation executes interrupt -> terminate -> close in order")
    func testCancellationEscalationSequence() async {
        let manager = AgentExecutionManager()
        let handle = MockExecutionHandle()

        await manager.registerActive(handle)
        await manager.cancelActive()

        #expect(handle.interruptCount == 1)
        #expect(handle.terminateCount == 1)
        #expect(handle.closeCount == 1)
        #expect(handle.events == ["interrupt", "terminate", "close"])

        let hasActive = await manager.hasActiveHandle
        #expect(!hasActive)
    }

    @Test("4. Early completion during grace period clears handle and prevents escalation")
    func testEarlyCompletionPreventsFurtherEscalation() async {
        let manager = AgentExecutionManager()
        let handle = MockExecutionHandle()

        await manager.registerActive(handle)

        Task {
            await manager.cancelActive()
        }

        // Wait 50ms (after interrupt, during grace period)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(handle.interruptCount == 1)

        // Process exits cleanly due to SIGINT -> clearActive is called
        await manager.clearActive()

        // Wait past the full grace period duration
        try? await Task.sleep(nanoseconds: 600_000_000)

        // Escalation should NOT have called terminate or close on this handle
        #expect(handle.terminateCount == 0)
        #expect(handle.closeCount == 0)
    }

    @Test("5. AgentEngine.cancel() triggers ExecutionManager cancellation")
    @MainActor
    func testAgentEngineCancelTriggersExecutionManager() async {
        let manager = AgentExecutionManager()
        let engine = AgentEngine(executionManager: manager)
        let handle = MockExecutionHandle()

        await manager.registerActive(handle)
        let hasActive = await manager.hasActiveHandle
        #expect(hasActive)

        engine.cancel()

        // Wait for Task { await executionManager.cancelActive() } to dispatch interrupt
        for _ in 0..<15 {
            if handle.interruptCount == 1 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(handle.interruptCount == 1)

        await manager.clearActive()
    }

    @Test("6. AnyCommandExecutionHandle correctly bridges closures")
    func testAnyCommandExecutionHandle() async throws {
        let flag = OSAllocatedUnfairLock<(interrupt: Bool, terminate: Bool, close: Bool)>(
            uncheckedState: (false, false, false)
        )

        let handle = AnyCommandExecutionHandle(
            onInterrupt: { flag.withLock { $0.interrupt = true } },
            onTerminate: { flag.withLock { $0.terminate = true } },
            onClose: { flag.withLock { $0.close = true } }
        )

        try await handle.interrupt()
        #expect(flag.withLock { $0.interrupt })

        try await handle.terminate()
        #expect(flag.withLock { $0.terminate })

        await handle.close()
        #expect(flag.withLock { $0.close })
    }

    @Test("7. PTYSessionCommandHandle sends Ctrl+C (0x03) on interrupt")
    func testPTYSessionCommandHandleSendsCtrlC() async throws {
        let pty = PTYSession()
        let handle = PTYSessionCommandHandle(ptySession: pty)

        let captured = OSAllocatedUnfairLock<[UInt8]>(uncheckedState: [])
        pty.inputTap = { bytes in
            captured.withLock { $0.append(contentsOf: bytes) }
        }

        try await handle.interrupt()

        let bytes = captured.withLock { $0 }
        #expect(bytes == [3]) // 0x03 == Ctrl+C / SIGINT
    }
}
