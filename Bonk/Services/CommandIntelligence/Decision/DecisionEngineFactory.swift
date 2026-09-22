//  DecisionEngineFactory.swift
//  Bonk
//
//  Builds the configured DecisionEngine. make returns the literal selection
//  (a misconfigured engine throws on use, which is what Settings → Test
//  surfaces); makeEffective substitutes the deterministic engine when the
//  selection cannot possibly work (Jev without a key), so hot paths never
//  pay for a doomed network call.

import Foundation

enum DecisionEngineFactory {
    static func make(
        config: DecisionEngineConfig,
        jevAPIKey: String,
        transport: any SystemOneTransport = URLSession.shared
    ) -> any DecisionEngine {
        switch config.engineID {
        case .jev:
            guard let endpoint = URL(string: config.jevEndpoint) else {
                return DeterministicDecisionEngine()
            }
            return JevDecisionEngine(
                endpoint: endpoint, model: config.jevModel,
                apiKey: jevAPIKey, transport: transport
            )
        case .laya:
            guard let endpoint = URL(string: config.layaEndpoint) else {
                return DeterministicDecisionEngine()
            }
            return LayaDecisionEngine(endpoint: endpoint, checkpoint: config.layaCheckpoint, transport: transport)
        }
    }

    /// Hot-path constructor. Falls back to deterministic when the selection
    /// is unusable without a network round-trip (Jev with no key).
    /// A reachable-but-failing engine still throws at call time and the
    /// caller keeps deterministic order — see CommandDecisionEngine.decideBest.
    static func makeEffective(
        config: DecisionEngineConfig = DecisionEngineConfig.load(),
        jevAPIKey: String = DecisionEngineKeychain.jevAPIKey,
        transport: any SystemOneTransport = URLSession.shared
    ) -> any DecisionEngine {
        if config.engineID == .jev, jevAPIKey.isEmpty {
            return DeterministicDecisionEngine()
        }
        return make(config: config, jevAPIKey: jevAPIKey, transport: transport)
    }
}
