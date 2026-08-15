//
//  ServerResourceMonitor.swift
//  Bonk
//
//  Lightweight resource monitor for the active SSH connection.
//  Polls once every 10 seconds and refreshes immediately when the active
//  tab or connection state changes, so the toolbar indicator stays fresh
//  without hammering the server with parallel exec channels.
//

import Foundation
import Observation

/// Snapshot of the active connection's latest resource data.
struct ServerResourceSnapshot: Equatable {
    let tabID: UUID
    let info: ServerInfo
}

@Observable
@MainActor
final class ServerResourceMonitor {
    static let shared = ServerResourceMonitor()

    private(set) var snapshot: ServerResourceSnapshot?

    private var pollTask: Task<Void, Never>?
    private weak var sessionManager: SessionManager?
    private var lastPollKey: (UUID?, Bool)?
    private var lastFetchDate = Date.distantPast
    private var lastNetworkSample: (rx: UInt64, tx: UInt64, at: Date)?
    private var lastDiskSample: (read: UInt64, write: UInt64, at: Date)?

    private init() {}

    func start(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tickIfNeeded()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        sessionManager = nil
        snapshot = nil
        lastPollKey = nil
        lastFetchDate = .distantPast
    }

    /// Force an immediate refresh (toolbar right-click).
    func refreshNow() async {
        lastFetchDate = .distantPast
        await tickIfNeeded()
    }

    // MARK: - Private

    private func tickIfNeeded() async {
        guard let manager = sessionManager else { return }
        let tab = manager.activeTab
        let key: (UUID?, Bool) = (tab?.id, tab?.session?.isConnected ?? false)

        // Refresh immediately on tab/connection change, otherwise at most
        // once every 10 seconds.
        let keyChanged: Bool = if let lastPollKey { key != lastPollKey } else { true }
        guard keyChanged || Date().timeIntervalSince(lastFetchDate) >= 10 else {
            return
        }
        lastPollKey = key

        guard let tab,
              let session = tab.session,
              session.isConnected,
              let service = session.sshService
        else {
            snapshot = nil
            return
        }

        if let info = await ServerInfoFetcher.fetch(using: service) {
            let withRates = applyingRates(to: info)
            session.serverInfo = withRates
            snapshot = ServerResourceSnapshot(tabID: tab.id, info: withRates)
            lastFetchDate = Date()
        }
    }

    /// Turn cumulative interface/disk counters into per-second rates.
    private func applyingRates(to info: ServerInfo) -> ServerInfo {
        var result = info
        let now = Date()

        if let rx = info.networkRXBytes, let tx = info.networkTXBytes {
            if let last = lastNetworkSample {
                let elapsed = now.timeIntervalSince(last.at)
                if elapsed >= 1, rx >= last.rx, tx >= last.tx {
                    result.networkRXRateBps = Double(rx - last.rx) / elapsed
                    result.networkTXRateBps = Double(tx - last.tx) / elapsed
                }
            }
            lastNetworkSample = (rx, tx, now)
        } else {
            lastNetworkSample = nil
        }

        if let read = info.diskReadBytes, let write = info.diskWriteBytes {
            if let last = lastDiskSample {
                let elapsed = now.timeIntervalSince(last.at)
                if elapsed >= 1, read >= last.read, write >= last.write {
                    result.diskReadRateBps = Double(read - last.read) / elapsed
                    result.diskWriteRateBps = Double(write - last.write) / elapsed
                }
            }
            lastDiskSample = (read, write, now)
        } else {
            lastDiskSample = nil
        }

        return result
    }
}
