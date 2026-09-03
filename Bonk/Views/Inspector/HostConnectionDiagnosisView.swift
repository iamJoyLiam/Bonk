import SwiftData
import SwiftUI

/// VNext §6.4 — Host Inspector: read-only diagnosis + Re-detect + forcedCompatibility toggle.
struct HostConnectionDiagnosisView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    var host: HostItem

    @State private var profiles: [SSHBackendProfile] = []
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Always-compatible toggle (§6.4 manual override)
            Toggle(isOn: Binding(
                get: { host.forceCompatibility == true },
                set: { newValue in
                    host.forceCompatibility = newValue ? true : nil
                    if !newValue {
                        // Clear diagnosis on close
                        let store = SSHProfileStore(context: modelContext)
                        let forced = store.profiles(forHost: host.host, port: host.port)
                            .filter { $0.reasonRaw == SSHBackendReason.forcedCompatibility.rawValue }
                        for profile in forced { modelContext.delete(profile) }
                        try? modelContext.save()
                    }
                    reload()
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(i18n.t(.sshAlwaysCompatibility))
                        .font(.system(size: AppStyle.fontBody, weight: .medium))
                    Text(i18n.t(.sshAlwaysCompatibilityDesc))
                        .font(.system(size: AppStyle.fontCaption))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Divider()

            if profiles.isEmpty {
                EmptyView()
            } else {
                let display = showAll ? profiles : Array(profiles.prefix(1))
                ForEach(display, id: \.id) { profile in
                    profileCard(profile)
                }
                if profiles.count > 1 {
                    Button(showAll ? "Show less" : "Show all (\(profiles.count))") {
                        showAll.toggle()
                    }
                    .font(.system(size: AppStyle.fontSmall))
                }
            }

            HStack {
                Button(i18n.t(.sshRedetect)) {
                    redetect()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
        }
        .onAppear { reload() }
        .onChange(of: host.forceCompatibility) { _, _ in reload() }
    }

    private func profileCard(_ profile: SSHBackendProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(profile.isValid ? Color.green : Color.orange)
                    .frame(width: AppStyle.iconMicro, height: AppStyle.iconMicro)
                Text(profile.backendRaw == SSHBackendType.native.rawValue
                    ? i18n.t(.sshBackendNative)
                    : i18n.t(.sshBackendCompatibility))
                    .font(.system(size: AppStyle.fontSmall, weight: .semibold))
                Text("· \(profile.reasonRaw)")
                    .font(.system(size: AppStyle.fontSmall, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(profile.isPolicyReason ? i18n.t(.sshPolicyNoExpiry)
                    : (profile.isValid ? i18n.t(.sshProfileValid) : i18n.t(.sshProfileExpired)))
                    .font(.system(size: AppStyle.fontCaption))
                    .padding(.horizontal, AppStyle.spacingS).padding(.vertical, AppStyle.spacingXXS)
                    .background(profile.isPolicyReason ? Color.blue.opacity(AppStyle.opacityBackgroundLight) : (profile.isValid ? Color.green.opacity(AppStyle.opacityBackgroundLight) : Color.orange.opacity(AppStyle.opacityBackgroundLight)))
                    .clipShape(Capsule())
            }

            // Auth + route
            Text("\(profile.authMethodRaw) · \(profile.host):\(profile.port)\(routeSummary(profile))")
                .font(.system(size: AppStyle.fontCaption, design: .monospaced))
                .foregroundStyle(.secondary)

            // Timestamps + Adaptive TTL
            HStack(spacing: 12) {
                Label(dateString(profile.detectedAt), systemImage: "clock")
                if !profile.isPolicyReason {
                    Label(dateString(profile.expiresAt), systemImage: "hourglass")
                }
            }
            .font(.system(size: AppStyle.fontCaption))
            .foregroundStyle(.secondary)

            // Adaptive TTL detail M4 Full
            HStack(spacing: 8) {
                Label("hit \(profile.effectiveHitCount) · TTL \(ttlLabel(profile))", systemImage: "arrow.triangle.2.circlepath")
                if let last = profile.lastHitAt {
                    Text("· last \(dateString(last))")
                }
                if profile.isPolicyReason {
                    Text("· policy永不过期")
                }
            }
            .font(.system(size: AppStyle.fontCaption, design: .monospaced))
            .foregroundStyle(.secondary)
            if !profile.isPolicyReason {
                let remaining = max(0, profile.expiresAt.timeIntervalSinceNow)
                let total = profile.adaptiveTTL
                let progress = total > 0 ? max(0, min(1, 1 - remaining / total)) : 0
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(profile.isValid ? Color.green : Color.orange)
            }

            // Negotiated full — nil when not yet captured
            if profile.negotiatedKEX != nil || profile.negotiatedHostKey != nil || profile.negotiatedCipher != nil || profile.negotiatedMAC != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Negotiated").font(.system(size: AppStyle.fontCaption, weight: .medium))
                    if let value = profile.negotiatedKEX { Text("KEX: \(value)").font(.system(size: AppStyle.fontCaption, design: .monospaced)) }
                    if let value = profile.negotiatedHostKey { Text("HostKey: \(value)").font(.system(size: AppStyle.fontCaption, design: .monospaced)) }
                    if let value = profile.negotiatedCipher { Text("Cipher: \(value)").font(.system(size: AppStyle.fontCaption, design: .monospaced)) }
                    if let value = profile.negotiatedMAC { Text("MAC: \(value)").font(.system(size: AppStyle.fontCaption, design: .monospaced)) }
                }
                .foregroundStyle(.secondary)
            }

            // Algorithms
            let algos = profile.algorithmRequirements
            if let algo = algos, !algo.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(i18n.t(.sshAlgorithms)).font(.system(size: AppStyle.fontCaption, weight: .medium))
                    if !algo.kex.isEmpty { Text("KEX: \(algo.kex.joined(separator: ", "))").font(.system(size: AppStyle.fontCaption, design: .monospaced)) }
                    if !algo.hostKey.isEmpty { Text("HostKey: \(algo.hostKey.joined(separator: ", "))").font(.system(size: AppStyle.fontCaption, design: .monospaced)) }
                    if !algo.cipher.isEmpty { Text("Cipher: \(algo.cipher.joined(separator: ", "))").font(.system(size: AppStyle.fontCaption, design: .monospaced)) }
                    if !algo.mac.isEmpty { Text("MAC: \(algo.mac.joined(separator: ", "))").font(.system(size: AppStyle.fontCaption, design: .monospaced)) }
                }
                .foregroundStyle(.secondary)
            }

            // Fingerprint
            if let citadelVer = profile.citadelVersion ?? profile.niosshVersion {
                Text("\(i18n.t(.sshFingerprint)): \(citadelVer) / \(profile.niosshVersion ?? "")")
                    .font(.system(size: AppStyle.fontCaption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppStyle.spacingM)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(AppStyle.opacityStroke)))
    }

    private func routeSummary(_ profile: SSHBackendProfile) -> String {
        guard let data = profile.routeData,
              let route = try? JSONDecoder().decode(SSHRoute.self, from: data),
              !route.hops.isEmpty else { return " · direct" }
        return " · via " + route.hops.map { $0.host }.joined(separator: "→")
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func ttlLabel(_ profile: SSHBackendProfile) -> String {
        if profile.isPolicyReason { return "policy" }
        switch profile.effectiveHitCount {
        case 1: return "1d"
        case 2: return "7d"
        default: return "30d"
        }
    }

    private func reload() {
        let store = SSHProfileStore(context: modelContext)
        profiles = store.profiles(forHost: host.host, port: host.port)
    }

    private func redetect() {
        let store = SSHProfileStore(context: modelContext)
        store.removeAll(forHost: host.host, port: host.port)
        reload()
    }
}
