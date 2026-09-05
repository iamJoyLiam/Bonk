//  ExecutionBoundary.swift
//  Bonk — ExecutionBoundary: CommandExecutionRequest → Policy → Gate → Adapter (Invariant #7)
//  P0: scaffolding — policy is allow-all, gate is no-op, adapter is PTY/SSH.

import Combine
import Foundation

struct CommandExecutionRequest: Sendable {
    let id: UUID
    let command: String
    let snapshot: CommandContextSnapshot
    let workspace: WorkspaceKind
    enum WorkspaceKind: Sendable { case local, remote(hostKey: String) }
}

struct ExecutionPolicy: Sendable {
    enum Decision: Sendable { case allow, requireApproval(reason: String), deny(reason: String) }
    func decide(_ req: CommandExecutionRequest) -> Decision {
        // P0: allow all; P1: deny rm -rf /, requireApproval for risky
        let lower = req.command.lowercased()
        if lower.contains("rm -rf /") || lower.contains("mkfs") { return .deny(reason: "Destructive") }
        if lower.hasPrefix("sudo") || lower.contains("chmod 777") { return .requireApproval(reason: "Risky") }
        return .allow
    }
}

@MainActor
final class ApprovalGate: ObservableObject {
    @Published var pending: CommandExecutionRequest?
    func requestApproval(for req: CommandExecutionRequest) async -> Bool {
        // P0: auto-approve; UI will present sheet in P1
        pending = req
        // Simulate user approval after 0 delay for now
        pending = nil
        return true
    }
}

enum ExecutionAdapter {
    static func execute(_ req: CommandExecutionRequest) async throws -> String {
        // P0: direct — later via PTY/SSH/SFTP adapters
        return "Executed: \(req.command)"
    }
}

@MainActor
final class ExecutionBoundary: ObservableObject {
    private let policy = ExecutionPolicy()
    private let gate = ApprovalGate()

    func submit(_ req: CommandExecutionRequest) async throws -> String {
        switch policy.decide(req) {
        case .allow:
            return try await ExecutionAdapter.execute(req)
        case .deny(let reason):
            throw ExecutionError.denied(reason)
        case .requireApproval:
            let ok = await gate.requestApproval(for: req)
            guard ok else { throw ExecutionError.cancelled }
            return try await ExecutionAdapter.execute(req)
        }
    }

    enum ExecutionError: LocalizedError {
        case denied(String), cancelled
        var errorDescription: String? {
            switch self { case .denied(let r): "Denied: \(r)"; case .cancelled: "Cancelled" }
        }
    }
}
