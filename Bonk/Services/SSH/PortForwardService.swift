//
//  PortForwardService.swift
//  Bonk
//
//  Port forwarding service for SSH tunnels.
//

import Foundation
import Citadel
import NIOCore
import NIOPosix
import os.log

/// Port forwarding service for SSH tunnels.
@Observable @MainActor
final class PortForwardService {
    static let shared = PortForwardService()

    private let logger = Logger(subsystem: "com.bonk", category: "PortForward")

    /// Active port forwardings.
    var activeForwards: [UUID: Bool] = [:]

    /// Whether any forwarding is active.
    var isActive: Bool { !activeForwards.isEmpty }

    private init() {}

    // MARK: - Public API

    /// Start a port forwarding.
    func start(config: PortForward) async throws {
        guard !isActive else {
            throw PortForwardError.alreadyRunning
        }

        activeForwards[config.id] = true

        do {
            switch config.type {
            case .local:
                try await startLocalForward(config: config)
            case .remote:
                try await startRemoteForward(config: config)
            case .dynamic:
                try await startDynamicForward(config: config)
            }
            config.isActive = true
            logger.info("Started port forwarding: \(config.displayDescription)")
        } catch {
            activeForwards.removeValue(forKey: config.id)
            throw error
        }
    }

    /// Stop a port forwarding.
    func stop(config: PortForward) async {
        guard activeForwards[config.id] == true else { return }

        activeForwards.removeValue(forKey: config.id)
        config.isActive = false
        logger.info("Stopped port forwarding: \(config.displayDescription)")
    }

    /// Stop all port forwardings.
    func stopAll() async {
        for (id, _) in activeForwards {
            activeForwards.removeValue(forKey: id)
        }
    }

    /// Get the status of a port forwarding.
    func status(for id: UUID) -> PortForwardStatus {
        guard activeForwards[id] == true else {
            return .stopped
        }
        return .running
    }

    // MARK: - Private

    private func startLocalForward(config: PortForward) async throws {
        // Create a local server that forwards connections through SSH
        // This is a placeholder implementation
        logger.info("Local forwarding not yet implemented: \(config.displayDescription)")
    }

    private func startRemoteForward(config: PortForward) async throws {
        // Request the remote server to forward connections
        // This requires SSH channel forwarding support
        throw PortForwardError.notImplemented
    }

    private func startDynamicForward(config: PortForward) async throws {
        // Create a SOCKS5 proxy server
        throw PortForwardError.notImplemented
    }
}

enum PortForwardStatus {
    case stopped
    case running
    case error(String)
}

// MARK: - Errors

enum PortForwardError: LocalizedError {
    case alreadyRunning
    case notRunning
    case serviceUnavailable
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Port forwarding is already running"
        case .notRunning:
            return "Port forwarding is not running"
        case .serviceUnavailable:
            return "Port forwarding service is unavailable"
        case .notImplemented:
            return "This type of port forwarding is not yet implemented"
        }
    }
}
