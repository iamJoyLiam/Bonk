//
//  PortForwardService.swift
//  Bonk
//
//  Port forwarding service for SSH tunnels.
//

import Foundation
import os.log

/// Port forwarding service for SSH tunnels.
@Observable @MainActor
final class PortForwardService {
    static let shared = PortForwardService()

    private let logger = Logger(subsystem: "com.bonk", category: "PortForward")

    /// Active port forwardings — stores the running Task and its config.
    /// The task is nil while a forward is still being started (claimed slot),
    /// so stop()/stopAll() can cancel an in-flight start too.
    private var activeTasks: [UUID: (task: Task<Void, Never>?, config: PortForward)] = [:]
    /// OpenSSH process handles.
    private var openSSHHandles: [UUID: OpenSSHForwardHandle] = [:]

    /// Whether any forwarding is active.
    var isActive: Bool {
        !activeTasks.isEmpty
    }

    private init() {}

    // MARK: - Public API

    /// Start a port forwarding.
    func start(
        config: PortForward,
        using sshService: SSHNetworkService? = nil
    ) async throws {
        guard activeTasks[config.id] == nil else {
            throw PortForwardError.alreadyRunning
        }

        guard let sshService else {
            throw PortForwardError.serviceUnavailable
        }

        // Claim the slot BEFORE the first await. stop()/stopAll() and a
        // concurrent start for the same config then see this entry instead of
        // racing us: stop removes the claim (cancelling the pending start
        // below), a second start fails with alreadyRunning.
        activeTasks[config.id] = (task: nil, config: config)

        let forward = SSHPortForwardConfiguration(
            type: {
                switch config.type {
                case .local: .local
                case .remote: .remote
                case .dynamic: .dynamic
                }
            }(),
            localHost: config.localHost,
            localPort: config.localPort,
            remoteHost: config.remoteHost,
            remotePort: config.remotePort
        )

        do {
            let handle = try await sshService.startPortForward(forward, onExit: {})
            // stop()/stopAll() may have removed our claim while we awaited;
            // close the freshly spawned tunnel so it does not outlive us.
            guard activeTasks[config.id] != nil else {
                handle.close()
                throw PortForwardError.alreadyRunning
            }
            let task = Task {
                await handle.waitUntilExit()
                await MainActor.run {
                    config.isActive = false
                    self.activeTasks.removeValue(forKey: config.id)
                    self.openSSHHandles.removeValue(forKey: config.id)
                }
            }
            activeTasks[config.id] = (task: task, config: config)
            openSSHHandles[config.id] = handle
            config.isActive = true
            logger.info("Started OpenSSH port forwarding: \(config.displayDescription)")
        } catch {
            // Release the claim on failure (keep the original error).
            activeTasks.removeValue(forKey: config.id)
            throw error
        }
    }

    /// Stop a port forwarding.
    func stop(config: PortForward) {
        guard let entry = activeTasks[config.id] else { return }
        entry.task?.cancel()
        activeTasks.removeValue(forKey: config.id)
        openSSHHandles.removeValue(forKey: config.id)?.close()
        config.isActive = false
        logger.info("Stopped port forwarding: \(config.displayDescription)")
    }

    /// Stop all port forwardings.
    func stopAll() {
        for (_, entry) in activeTasks {
            entry.task?.cancel()
            entry.config.isActive = false
        }
        activeTasks.removeAll()
        openSSHHandles.values.forEach { $0.close() }
        openSSHHandles.removeAll()
    }
}

// MARK: - Errors

enum PortForwardError: LocalizedError {
    case alreadyRunning
    case serviceUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Port forwarding is already running"
        case .serviceUnavailable:
            "SSH connection not available for port forwarding"
        }
    }
}