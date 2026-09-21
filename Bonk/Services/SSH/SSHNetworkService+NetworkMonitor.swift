//
//  SSHNetworkService+NetworkMonitor.swift
//  Bonk
//
//  Network connectivity monitoring extracted from SSHNetworkService to keep the
//  actor body within size limits. Same-module extension: internal members only.
//

@preconcurrency import Citadel
import Crypto
import Foundation
import Network
import NIOConcurrencyHelpers
import NIOCore
@preconcurrency import NIOSSH
import os.log

// MARK: - SSHNetworkService Network Monitoring

extension SSHNetworkService {
    /// Start monitoring network connectivity changes.
    func startNetworkMonitor() {
        guard !isMonitoringNetwork else { return }
        isMonitoringNetwork = true
        // A cancelled NWPathMonitor cannot be restarted — always build a
        // fresh instance (stopNetworkMonitor() cancels the previous one).
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        let queue = DispatchQueue(label: "com.bonk.ssh.network-monitor")
        monitor.pathUpdateHandler = { [weak self] path in
            Task {
                await self?.handleNetworkChange(path)
            }
        }
        monitor.start(queue: queue)
    }

    /// Stop monitoring network connectivity.
    func stopNetworkMonitor() {
        networkMonitor?.cancel()
        networkMonitor = nil
        isMonitoringNetwork = false
        isWaitingForNetwork = false
    }

    /// Network-recovery only: the old transport was already probed dead.
    /// Close it now so the server frees the session slot before the first
    /// reconnect attempt, instead of racing it under make-before-break
    /// (stale server-side sessions are what turn attempt 1 into backoff).
    /// Best-effort and non-throwing; never touches PTY/session state, which
    /// the reconnect pipeline rebuilds on success.
    func closeStaleTransport() async {
        if usesOpenSSHTransport {
            openSSHBackend?.close()
        } else {
            try? await client?.close()
        }
    }

    /// Handle network connectivity changes - funnel through supervisor per P0.
    /// Fix 3: only on unsatisfied->satisfied transition + per-session health gate
    private func handleNetworkChange(_ path: NWPath) async {
        let isSatisfied = path.status == .satisfied
        defer { lastNetworkPathWasSatisfied = isSatisfied }
        guard isSatisfied else { return }
        // Only trigger on transition, not every satisfied event (NWPathMonitor is app-global)
        if lastNetworkPathWasSatisfied == true {
            Log.ssh.info("[NETWORK] ignore networkChanged - already satisfied (spurious)")
            return
        }
        guard config != nil else { return }
        if case .connecting = connectionState {
            Log.ssh.info("[NETWORK] ignore networkChanged during connecting")
            return
        }
        if usesOpenSSHTransport, activePTYSession == nil, lastPTYConfig == nil {
            Log.ssh.info("[NETWORK] ignore networkChanged - PTY not yet created (connect window)")
            return
        }
        if let typedFailure = pendingFailure, typedFailure.isAuthentication || typedFailure.typeString == "hostKey" || typedFailure.typeString == "cancelled" {
            Log.ssh.info("[RECOVERY_GATE] blocked=true reason=\(typedFailure.typeString, privacy: .public) handleNetworkChange suppressed")
            return
        }
        // Per-session health check: if transport/PTY still alive, ignore (Fix 3).
        // The alive branch returns WITHOUT closing anything: a live transport
        // must never be killed by a network event (flapping/jitter safety).
        let alive = await probeLiveness()
        if alive {
            Log.ssh.info("[NETWORK] ignore networkChanged - probe alive, session healthy")
            return
        }
        // Network recovery with a confirmed-dead old transport: release it
        // now (frees the server-side session slot for attempt 1) and enter
        // the pipeline with the probe result — no second probe burns 5s.
        Log.ssh.info("[NETWORK] old transport probed dead, closing stale transport before recovery...")
        await closeStaleTransport()
        await supervisor.requestRecovery(reason: .networkChanged, preProbed: .dead)
    }
}
