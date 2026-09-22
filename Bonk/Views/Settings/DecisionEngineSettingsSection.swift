import SwiftUI

/// Liveness state for Settings → Decision Engine → Test.
private enum DecisionEngineStatus: Equatable {
    case idle
    case checking
    case ok
    case failed(String)
}

/// Decision Intelligence settings: engine picker (Local / Jev / Laya),
/// suggestion confidence threshold, routing cost policy, per-engine
/// connection details, and a live Test button. All values persist under
/// "decision.*" keys (see DecisionEngineConfig); the Jev key lives in the
/// Keychain and never touches UserDefaults.
struct DecisionEngineSettingsSection: View {
    @Environment(I18n.self) var i18n

    @AppStorage("decision.engine.id") private var decisionEngineIDRaw = "jev"
    @AppStorage("decision.gate.threshold") private var decisionThreshold = 0.75
    @AppStorage("routing.cost.policy") private var costPolicyRaw = "any"
    @AppStorage("decision.jev.endpoint") private var jevEndpoint = "https://api.typesafe.ai"
    @AppStorage("decision.jev.model") private var jevModel = "jev-latest"
    @AppStorage("decision.laya.endpoint") private var layaEndpoint = "http://127.0.0.1:8765"
    @AppStorage("decision.laya.checkpoint") private var layaCheckpoint = ""

    @State private var jevKeyInput = ""
    @State private var jevKeySet = false
    @State private var engineTesting = false
    @State private var engineStatus: DecisionEngineStatus = .idle

    private var decisionEngineID: DecisionEngineID {
        DecisionEngineID(rawValue: decisionEngineIDRaw) ?? .jev
    }

    private var strictnessCaption: String {
        switch decisionThreshold {
        case ..<0.65: return i18n.t(.decisionStrictnessOpen)
        case ..<0.85: return i18n.t(.decisionStrictnessBalanced)
        case ..<0.95: return i18n.t(.decisionStrictnessCautious)
        default: return i18n.t(.decisionStrictnessStrict)
        }
    }

    /// Test is meaningless for Jev without a key — disable with a hint
    /// instead of failing with a cryptic error.
    private var jevNeedsKey: Bool {
        decisionEngineID == .jev && !jevKeySet && jevKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Section {
            Picker(i18n.t(.decisionEngineChoice), selection: $decisionEngineIDRaw) {
                ForEach(DecisionEngineID.allCases, id: \.self) { engine in
                    Text(engine.displayName).tag(engine.rawValue)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Slider(value: $decisionThreshold, in: 0.5 ... 1.0, step: 0.05) {
                        Text(i18n.t(.decisionStrictness))
                    }
                    Text("\(Int(decisionThreshold * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(strictnessCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker(i18n.t(.routingCost), selection: $costPolicyRaw) {
                Text(i18n.t(.routingCostAuto)).tag("any")
                Text(i18n.t(.routingCostFreeOnly)).tag("freeOnly")
            }
            if decisionEngineID == .jev {
                HStack {
                    SecureField(jevKeySet ? i18n.t(.apiKeySet) : i18n.t(.jevAPIKey), text: $jevKeyInput)
                        .onSubmit(saveJevKey)
                    // The secret itself is never displayed; the checkmark is
                    // the only visible proof a key is stored.
                    if jevKeySet {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help(i18n.t(.apiKeySet))
                    }
                }
                TextField(i18n.t(.jevEndpoint), text: $jevEndpoint)
                TextField(i18n.t(.jevModel), text: $jevModel)
            }
            if decisionEngineID == .laya {
                TextField(i18n.t(.layaEndpoint), text: $layaEndpoint)
                TextField(i18n.t(.layaCheckpoint), text: $layaCheckpoint)
                    .overlay(alignment: .trailing) {
                        if layaCheckpoint.isEmpty {
                            Text(i18n.t(.layaCheckpointAuto))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
            }
            HStack {
                Button(i18n.t(.testDecisionEngine)) {
                    Task { await testDecisionEngine() }
                }
                .disabled(engineTesting || jevNeedsKey)
                engineStatusView
            }
        } header: {
            Text(i18n.t(.decisionEngine))
        } footer: {
            if decisionEngineID == .laya {
                Text(i18n.t(.layaBridgeHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if decisionEngineID == .jev, jevNeedsKey {
                Text(i18n.t(.jevKeyRequired))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            jevKeySet = !DecisionEngineKeychain.jevAPIKey.isEmpty
        }
        // A stale "Connected" from the previous engine must not survive the switch.
        .onChange(of: decisionEngineIDRaw) {
            engineStatus = .idle
        }
    }

    private var engineStatusView: some View {
        Group {
            switch engineStatus {
            case .idle:
                EmptyView()
            case .checking:
                ProgressView().controlSize(.small)
            case .ok:
                Text(i18n.t(.decisionEngineOK)).foregroundStyle(.green)
            case let .failed(reason):
                Text("\(i18n.t(.decisionEngineFailed)): \(reason)")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private func saveJevKey() {
        let trimmed = jevKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        DecisionEngineKeychain.setJevAPIKey(trimmed)
        jevKeyInput = ""
        jevKeySet = true
    }

    private func testDecisionEngine() {
        // The key field commits on Enter; a user who types then clicks Test
        // directly would otherwise test an empty keychain value.
        if !jevKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saveJevKey()
        }
        let id = decisionEngineID
        engineTesting = true
        engineStatus = .checking
        Task {
            let status: DecisionEngineStatus
            do {
                switch id {
                case .jev:
                    guard let endpoint = URL(string: jevEndpoint) else {
                        status = .failed(jevEndpoint); break
                    }
                    let engine = JevDecisionEngine(
                        endpoint: endpoint, model: jevModel,
                        apiKey: DecisionEngineKeychain.jevAPIKey
                    )
                    try await engine.checkHealth()
                    status = .ok
                case .laya:
                    guard let endpoint = URL(string: layaEndpoint) else {
                        status = .failed(layaEndpoint); break
                    }
                    let engine = LayaDecisionEngine(endpoint: endpoint, checkpoint: layaCheckpoint)
                    try await engine.checkHealth()
                    status = .ok
                }
            } catch {
                status = .failed(error.localizedDescription)
            }
            await MainActor.run {
                engineStatus = status
                engineTesting = false
            }
        }
    }
}
