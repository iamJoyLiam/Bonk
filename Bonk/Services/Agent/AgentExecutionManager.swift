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
public actor AgentExecutionManager {
    public static let shared = AgentExecutionManager()

    private(set) var activeHandle: (any CommandExecutionHandle)?
    private var isCancelling = false

    public init() {}

    public func registerActive(_ handle: any CommandExecutionHandle) {
        activeHandle = handle
        isCancelling = false
    }

    public func clearActive() {
        activeHandle = nil
        isCancelling = false
    }

    public var hasActiveHandle: Bool {
        activeHandle != nil
    }

    /// Cancel the active command with progressive escalation:
    /// 1. Interrupt (0x03 / SIGINT)
    /// 2. 300ms grace period
    /// 3. Terminate (SIGTERM)
    /// 4. 200ms grace period
    /// 5. Force close channel / FD
    public func cancelActive() async {
        guard let handle = activeHandle, !isCancelling else { return }
        isCancelling = true

        Log.ai.info("[AgentExecutionManager] Initiating hard cancellation: sending interrupt (0x03)")
        do {
            try await handle.interrupt()
        } catch {
            Log.ai.warning("[AgentExecutionManager] Interrupt failed: \(error.localizedDescription)")
        }

        // Grace period (300ms)
        try? await Task.sleep(nanoseconds: 300_000_000)

        guard isCancelling, activeHandle != nil else { return }

        Log.ai.info("[AgentExecutionManager] Escalating cancellation: sending terminate (SIGTERM)")
        do {
            try await handle.terminate()
        } catch {
            Log.ai.warning("[AgentExecutionManager] Terminate failed: \(error.localizedDescription)")
        }

        // Grace period (200ms)
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard isCancelling, activeHandle != nil else { return }

        Log.ai.info("[AgentExecutionManager] Escalating cancellation: closing channel / FD")
        await handle.close()
        activeHandle = nil
        isCancelling = false
    }
}
