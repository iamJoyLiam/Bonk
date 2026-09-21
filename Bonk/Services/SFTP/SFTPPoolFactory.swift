//
//  SFTPPoolFactory.swift
//  Bonk
//
//  Commit-3: production pool construction behind a narrow seam.
//  The factory only executes: configuration in, pool out. It never
//  decides RTT, size policy, mc2/mc4 selection, or engine routing —
//  those belong to SFTPTransferPlanner (Why). Factory is How,
//  SFTPParallelTransferEngine is Execute.
//

import Foundation

/// Narrow pool-construction seam, injected at connect time.
/// Deliberately dumb: no RTT/size/policy logic inside.
protocol SFTPPoolFactory: Sendable {
    func makePool(configuration: SFTPPoolConfiguration) async throws -> [PooledSFTPHandle]
}

/// Everything a pool build needs, decided upstream by the planner.
struct SFTPPoolConfiguration: Sendable {
    var connectionConfig: SSHConnectionConfig
    var hostKeyStore: any SSHHostKeyStore
    var shards: Int
}

/// Production factory: delegates to the proven pool builder.
struct DefaultSFTPPoolFactory: SFTPPoolFactory {
    func makePool(configuration: SFTPPoolConfiguration) async throws -> [PooledSFTPHandle] {
        try await SFTPMultiTCPPool.makePool(
            config: configuration.connectionConfig,
            hostKeyStore: configuration.hostKeyStore,
            count: configuration.shards
        )
    }
}
