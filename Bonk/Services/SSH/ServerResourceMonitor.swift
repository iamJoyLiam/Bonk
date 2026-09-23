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
    private static let maxConcurrentPolls = 3
    /// Heavy details (top processes, listening ports) refresh at most this often.
    private static let heavyRefreshInterval: TimeInterval = 60
    static let shared = ServerResourceMonitor()

    private(set) var snapshot: ServerResourceSnapshot?
    /// All connected hosts' latest info, keyed by tabID. Enables sidebar "all hosts" view.
    private(set) var allSnapshots: [UUID: ServerInfo] = [:]

    private var pollTask: Task<Void, Never>?
    private weak var sessionManager: SessionManager?
    private var lastPollKey: (UUID?, Bool)?
    private var lastFetchDate = Date.distantPast
    private var lastNetworkSamples: [UUID: (receivedBytes: UInt64, transmittedBytes: UInt64, atValue: Date)] = [:]
    private var lastDiskSamples: [UUID: (read: UInt64, write: UInt64, atValue: Date)] = [:]
    /// Static facts per tab, fetched once per connection.
    private var staticCache: [UUID: ServerInfo] = [:]
    /// Last heavy layer per tab; merged over fast on every tick.
    private var heavyCache: [UUID: ServerInfo] = [:]
    private var lastHeavyFetch: [UUID: Date] = [:]
    /// Set by refreshNow (toolbar right-click / popover button): next tick
    /// refreshes the heavy layer immediately instead of waiting out the 60s.
    private var forceHeavyRefresh = false

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
        allSnapshots = [:]
        lastPollKey = nil
        lastFetchDate = .distantPast
        lastNetworkSamples = [:]
        lastDiskSamples = [:]
        staticCache = [:]
        heavyCache = [:]
        lastHeavyFetch = [:]
        forceHeavyRefresh = false
    }

    /// Force an immediate refresh (toolbar right-click).
    func refreshNow() async {
        lastFetchDate = .distantPast
        forceHeavyRefresh = true
        await tickIfNeeded()
    }

    // MARK: - Private

    private func tickIfNeeded() async {
        guard let manager = sessionManager else { return }
        let tabs = manager.tabs
        let activeID = manager.activeTabID
        let isActiveConnected = manager.activeTab?.session?.isConnected ?? false
        let key: (UUID?, Bool) = (activeID, isActiveConnected)
        let keyChanged: Bool = if let lastPollKey { key != lastPollKey } else { true }
        guard keyChanged || Date().timeIntervalSince(lastFetchDate) >= 10 else { return }
        lastPollKey = key
        if keyChanged {
            // New active tab → drop its old counters so first sample never crosses hosts
            if let aid = activeID {
                lastNetworkSamples[aid] = nil
                lastDiskSamples[aid] = nil
            }
        }

        // P0:  ready  3s  command， auth  Server info fetch  PTY  password responder
        let candidates: [(tab: TerminalTab, service: SSHNetworkService)] = tabs.compactMap { tab in
            guard let session = tab.session, session.isReady, let svc = session.sshService else { return nil }
            // ready  3s ， PTY
            if let atValue = session.connectedAt, Date().timeIntervalSince(atValue) < 3 { return nil }
            return (tab, svc)
        }
        if candidates.isEmpty {
            snapshot = nil
            // Prune allSnapshots for disconnected tabs
            allSnapshots = [:]
            staticCache = [:]
            heavyCache = [:]
            lastHeavyFetch = [:]
            lastFetchDate = Date()
            return
        }

        let startedFetch = Date()
        let forceHeavy = forceHeavyRefresh
        forceHeavyRefresh = false
        // Layer plan per tab, computed synchronously before fanning out.
        let plans: [(tab: TerminalTab, service: SSHNetworkService, needStatic: Bool, needHeavy: Bool)] =
            candidates.map { (tab, service) in
                let needStatic = staticCache[tab.id] == nil
                let lastHeavy = lastHeavyFetch[tab.id]
                let needHeavy = forceHeavy || lastHeavy == nil
                    || startedFetch.timeIntervalSince(lastHeavy!) >= Self.heavyRefreshInterval
                return (tab, service, needStatic, needHeavy)
            }
        var results: [(UUID, ServerInfo)] = []
        // Capped concurrency: process candidates in batches of maxConcurrentPolls to avoid thread/NIO explosion
        for chunk in plans.chunked(into: Self.maxConcurrentPolls) {
            await withTaskGroup(of: (UUID, ServerInfo?, ServerInfo?, ServerInfo?)?.self) { group in
                for plan in chunk {
                    group.addTask {
                        async let staticInfo: ServerInfo? = plan.needStatic
                            ? ServerInfoFetcher.fetchStatic(using: plan.service) : nil
                        async let fastInfo: ServerInfo? = ServerInfoFetcher.fetchFast(using: plan.service)
                        async let heavyInfo: ServerInfo? = plan.needHeavy
                            ? ServerInfoFetcher.fetchHeavy(using: plan.service) : nil
                        return (plan.tab.id, await staticInfo, await fastInfo, await heavyInfo)
                    }
                }
                for await res in group {
                    guard let (tabID, staticInfo, fastInfo, heavyInfo) = res,
                          let fast = fastInfo
                    else { continue }
                    // Fast layer failed → keep last-known snapshot (existing behavior).
                    if let staticInfo { self.staticCache[tabID] = staticInfo }
                    guard let base = self.staticCache[tabID] else { continue }
                    var merged = base.overlaying(fast)
                    if let heavyInfo {
                        self.heavyCache[tabID] = heavyInfo
                        self.lastHeavyFetch[tabID] = startedFetch
                    }
                    if let heavy = self.heavyCache[tabID] {
                        merged = merged.overlaying(heavy)
                    }
                    results.append((tabID, merged))
                }
            }
        }

        for (tabID, info) in results {
            let withRates = applyingRates(to: info, for: tabID)
            // Update per-tab session.serverInfo
            if let tab = tabs.first(where: { $0.id == tabID }) {
                tab.session?.serverInfo = withRates
            }
            allSnapshots[tabID] = withRates
            if tabID == activeID {
                snapshot = ServerResourceSnapshot(tabID: tabID, info: withRates)
            }
        }
        // Prune snapshots for tabs that are no longer connected
        let liveIDs = Set(candidates.map { $0.tab.id })
        for key in allSnapshots.keys where !liveIDs.contains(key) {
            allSnapshots.removeValue(forKey: key)
            lastNetworkSamples.removeValue(forKey: key)
            lastDiskSamples.removeValue(forKey: key)
            staticCache.removeValue(forKey: key)
            heavyCache.removeValue(forKey: key)
            lastHeavyFetch.removeValue(forKey: key)
        }
        // If active tab is disconnected, clear its snapshot
        if let aid = activeID, !liveIDs.contains(aid) {
            snapshot = nil
        }
        lastFetchDate = startedFetch
    }

    /// Per-tab rates
    private func applyingRates(to info: ServerInfo, for tabID: UUID) -> ServerInfo {
        var result = info
        let now = Date()
        if let receivedBytes = info.networkRXBytes, let transmittedBytes = info.networkTXBytes {
            if let last = lastNetworkSamples[tabID] {
                let elapsed = now.timeIntervalSince(last.atValue)
                if elapsed >= 1, receivedBytes >= last.receivedBytes, transmittedBytes >= last.transmittedBytes {
                    result.networkRXRateBps = Double(receivedBytes - last.receivedBytes) / elapsed
                    result.networkTXRateBps = Double(transmittedBytes - last.transmittedBytes) / elapsed
                }
            }
            lastNetworkSamples[tabID] = (receivedBytes, transmittedBytes, now)
        } else {
            lastNetworkSamples[tabID] = nil
        }
        if let read = info.diskReadBytes, let write = info.diskWriteBytes {
            if let last = lastDiskSamples[tabID] {
                let elapsed = now.timeIntervalSince(last.atValue)
                if elapsed >= 1, read >= last.read, write >= last.write {
                    result.diskReadRateBps = Double(read - last.read) / elapsed
                    result.diskWriteRateBps = Double(write - last.write) / elapsed
                }
            }
            lastDiskSamples[tabID] = (read, write, now)
        } else {
            lastDiskSamples[tabID] = nil
        }
        return result
    }

    // Legacy single-sample helper kept for tests that call applyingRates directly
    private func applyingRates(to info: ServerInfo) -> ServerInfo {
        // Fallback to active tab's samples if available, else global
        if let aid = sessionManager?.activeTabID { return applyingRates(to: info, for: aid) }
        var result = info
        let now = Date()
        // Use first sample if any
        if let receivedBytes = info.networkRXBytes, let transmittedBytes = info.networkTXBytes {
            if let last = lastNetworkSamples.values.first {
                let elapsed = now.timeIntervalSince(last.atValue)
                if elapsed >= 1, receivedBytes >= last.receivedBytes, transmittedBytes >= last.transmittedBytes {
                    result.networkRXRateBps = Double(receivedBytes - last.receivedBytes) / elapsed
                    result.networkTXRateBps = Double(transmittedBytes - last.transmittedBytes) / elapsed
                }
            }
        }
        if let read = info.diskReadBytes, let write = info.diskWriteBytes {
            if let last = lastDiskSamples.values.first {
                let elapsed = now.timeIntervalSince(last.atValue)
                if elapsed >= 1, read >= last.read, write >= last.write {
                    result.diskReadRateBps = Double(read - last.read) / elapsed
                    result.diskWriteRateBps = Double(write - last.write) / elapsed
                }
            }
        }
        return result
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0+size, count)]) }
    }
}
