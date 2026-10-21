//
//  AgentExecutionManager.swift
//  Bonk
//
//  P0.2 Agent Hard Cancellation & Execution Governance.
//

import Darwin
import Foundation
import os.log

/// Command execution handle contract for active execution channels.
/// Any executing channel (PTY / NativeSSH / OpenSSH / Process) registers a handle
/// with `AgentExecutionManager` so cancellation can escalate from SIGINT (0x03) to terminate and close.
public protocol CommandExecutionHandle: Sendable {
    /// Send SIGINT (0x03 / Ctrl+C) to active channel or process.
    func interrupt() async throws
    /// Escalate to terminate (SIGTERM / double break).
    func terminate() async throws
    /// Final escalation: forcibly close channel / FD.
    func close() async
}

/// Callback invoked when an execution channel starts, so the caller can
/// register the live handle for cancellation.
///
/// Async by contract: the channel awaits registration before proceeding,
/// which forms a deterministic sync boundary — once the channel runs,
/// a concurrent cancel() is guaranteed to observe the handle. A
/// fire-and-forget Task here would reopen the register/cancel race.
public typealias CommandHandleRegistration = @Sendable (any CommandExecutionHandle) async -> Void

/// Type-erased closure-based CommandExecutionHandle for lightweight adaptation.
public struct AnyCommandExecutionHandle: CommandExecutionHandle {
    private let onInterrupt: @Sendable () async throws -> Void
    private let onTerminate: @Sendable () async throws -> Void
    private let onClose: @Sendable () async -> Void

    public init(
        onInterrupt: @escaping @Sendable () async throws -> Void,
        onTerminate: @escaping @Sendable () async throws -> Void = {},
        onClose: @escaping @Sendable () async -> Void = {}
    ) {
        self.onInterrupt = onInterrupt
        self.onTerminate = onTerminate
        self.onClose = onClose
    }

    public func interrupt() async throws {
        try await onInterrupt()
    }

    public func terminate() async throws {
        try await onTerminate()
    }

    public func close() async {
        await onClose()
    }
}

#if os(macOS)
/// Execution handle directly managing an OpenSSHProcessTransport and its PTYSession.
final class ProcessCommandExecutionHandle: CommandExecutionHandle, @unchecked Sendable {
    private let process: OpenSSHProcessTransport
    private let session: PTYSession

    init(process: OpenSSHProcessTransport, session: PTYSession) {
        self.process = process
        self.session = session
    }

    public func interrupt() async throws {
        // Write Ctrl+C (0x03) to PTY masterFD — line discipline sends SIGINT to foreground group
        try? process.write(Data([0x03]))
        let pid = process.processID
        if pid > 0 {
            kill(pid, SIGINT)
        }
    }

    public func terminate() async throws {
        let pid = process.processID
        if pid > 0 {
            kill(pid, SIGTERM)
        }
    }

    public func close() async {
        session.close()
        process.close()
    }
}
#endif

/// Execution handle managing an interactive PTYSession.
public final class PTYSessionCommandHandle: CommandExecutionHandle, @unchecked Sendable {
    private let ptySession: PTYSession

    public init(ptySession: PTYSession) {
        self.ptySession = ptySession
    }

    public func interrupt() async throws {
        let ctrlC: ArraySlice<UInt8> = [3]
        try? await ptySession.sendInput(ctrlC)
    }

    public func terminate() async throws {
        let ctrlC: ArraySlice<UInt8> = [3, 3]
        try? await ptySession.sendInput(ctrlC)
    }

    public func close() async {
        ptySession.close()
    }
}

/// Actor managing active command execution handles for AI Agent tasks.
/// Governs the escalation lifecycle: Interrupt (0x03) -> Grace Period -> Terminate -> Grace Period -> Close.
///
/// **A set, not a slot.** Commands can run in parallel, so more than one
/// can be live at a time. A single slot meant the second command
/// overwrote the first: cancelling then interrupted whichever registered
/// last and left the other one running. That was invisible while commands
/// ran one at a time, and wrong as soon as they do not.
public actor AgentExecutionManager {
    public static let shared = AgentExecutionManager()

    /// The live handles, in registration order.
    private var activeHandles: [(any CommandExecutionHandle)] = []
    private var isCancelling = false

    public init() {}

    public func registerActive(_ handle: any CommandExecutionHandle) {
        activeHandles.append(handle)
        isCancelling = false
    }

    public func clearActive() {
        activeHandles.removeAll()
        isCancelling = false
    }

    public var hasActiveHandle: Bool {
        !activeHandles.isEmpty
    }

    /// How many commands are live right now.
    public var activeHandleCount: Int {
        activeHandles.count
    }

    /// Cancel the live commands with progressive escalation:
    /// 1. Interrupt (0x03 / SIGINT)
    /// 2. 300ms grace period
    /// 3. Terminate (SIGTERM)
    /// 4. 200ms grace period
    /// 5. Force close channel / FD
    ///
    /// Every live command is escalated, not just one of them: the user
    /// asked for all of them to stop.
    public func cancelActive() async {
        let handles = activeHandles
        guard !handles.isEmpty, !isCancelling else { return }
        isCancelling = true

        Log.ai.info("[AgentExecutionManager] Initiating hard cancellation: sending interrupt (0x03)")
        for handle in handles {
            do {
                try await handle.interrupt()
            } catch {
                Log.ai.warning("[AgentExecutionManager] Interrupt failed: \(error.localizedDescription)")
            }
        }

        // Grace period (300ms)
        try? await Task.sleep(nanoseconds: 300_000_000)

        guard isCancelling, !activeHandles.isEmpty else { return }

        Log.ai.info("[AgentExecutionManager] Escalating cancellation: sending terminate (SIGTERM)")
        for handle in handles {
            do {
                try await handle.terminate()
            } catch {
                Log.ai.warning("[AgentExecutionManager] Terminate failed: \(error.localizedDescription)")
            }
        }

        // Grace period (200ms)
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard isCancelling, !activeHandles.isEmpty else { return }

        Log.ai.info("[AgentExecutionManager] Escalating cancellation: closing channel / FD")
        for handle in handles {
            await handle.close()
        }
        activeHandles.removeAll()
        isCancelling = false
    }
}
