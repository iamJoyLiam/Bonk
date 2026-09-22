//  DecisionEngineConfig.swift
//  Bonk
//
//  User-facing configuration for the Decision Intelligence layer.
//  Plain values persist in UserDefaults (injectable for tests); the Jev API
//  key lives in the Keychain and never touches UserDefaults.

import Foundation

/// Which engine answers typed decisions. No "local" option: the
/// deterministic ordering is the automatic fallback everywhere (engine
/// abstains, fails, or is unconfigured), never a selectable engine.
enum DecisionEngineID: String, Sendable, CaseIterable {
    case jev
    case laya

    var displayName: String {
        switch self {
        case .jev: return "Jev"
        case .laya: return "Laya"
        }
    }
}

/// Persisted decision-engine settings. All keys namespaced under "decision.".
struct DecisionEngineConfig: Sendable, Equatable {
    var engineID: DecisionEngineID = .jev
    /// Gate threshold in [0, 1]. Model judgments below it are ignored and
    /// the deterministic order stands. Default 0.75.
    var decisionThreshold: Double = 0.75
    var costPolicy: RoutingCostPolicy = .any

    var jevEndpoint: String = "https://api.typesafe.ai"
    var jevModel: String = "jev-latest"

    var layaEndpoint: String = "http://127.0.0.1:8765"
    /// Empty = let the local Laya Router pick the checkpoint automatically.
    var layaCheckpoint: String = ""

    // MARK: - Persistence

    private enum Keys {
        static let engineID = "decision.engine.id"
        static let decisionThreshold = "decision.gate.threshold"
        static let costPolicy = "routing.cost.policy"
        static let jevEndpoint = "decision.jev.endpoint"
        static let jevModel = "decision.jev.model"
        static let layaEndpoint = "decision.laya.endpoint"
        static let layaCheckpoint = "decision.laya.checkpoint"
    }

    static func load(from defaults: UserDefaults = .standard) -> DecisionEngineConfig {
        var config = DecisionEngineConfig()
        if let raw = defaults.string(forKey: Keys.engineID),
           let id = DecisionEngineID(rawValue: raw) {
            config.engineID = id
        }
        if defaults.object(forKey: Keys.decisionThreshold) != nil {
            config.decisionThreshold = min(1.0, max(0.0, defaults.double(forKey: Keys.decisionThreshold)))
        }
        if defaults.string(forKey: Keys.costPolicy) == "freeOnly" {
            config.costPolicy = .freeOnly
        }
        if let endpoint = defaults.string(forKey: Keys.jevEndpoint), !endpoint.isEmpty {
            config.jevEndpoint = endpoint
        }
        if let model = defaults.string(forKey: Keys.jevModel), !model.isEmpty {
            config.jevModel = model
        }
        if let endpoint = defaults.string(forKey: Keys.layaEndpoint), !endpoint.isEmpty {
            config.layaEndpoint = endpoint
        }
        // Checkpoint may legitimately be empty (router auto), so read raw.
        config.layaCheckpoint = defaults.string(forKey: Keys.layaCheckpoint) ?? ""
        return config
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(engineID.rawValue, forKey: Keys.engineID)
        defaults.set(decisionThreshold, forKey: Keys.decisionThreshold)
        defaults.set(costPolicy == .freeOnly ? "freeOnly" : "any", forKey: Keys.costPolicy)
        defaults.set(jevEndpoint, forKey: Keys.jevEndpoint)
        defaults.set(jevModel, forKey: Keys.jevModel)
        defaults.set(layaEndpoint, forKey: Keys.layaEndpoint)
        defaults.set(layaCheckpoint, forKey: Keys.layaCheckpoint)
    }
}

// MARK: - Jev API key (Keychain, never UserDefaults)

enum DecisionEngineKeychain {
    private static let jevAccount = "decision_engine_jev_api_key"

    static var jevAPIKey: String {
        KeychainHelper.get(for: jevAccount) ?? ""
    }

    static func setJevAPIKey(_ key: String) {
        if key.isEmpty {
            KeychainHelper.delete(for: jevAccount)
        } else {
            KeychainHelper.set(key, for: jevAccount)
        }
    }
}
