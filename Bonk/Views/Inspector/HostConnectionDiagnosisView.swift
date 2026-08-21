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
                        // 关闭即清空历史强制诊断，下一连回 nativeWithFallback 试探
                        let store = SSHProfileStore(context: modelContext)
                        let forced = store.profiles(forHost: host.host, port: host.port)
                            .filter { $0.reasonRaw == SSHBackendReason.forcedCompatibility.rawValue }
                        for p in forced { modelContext.delete(p) }
                        try? modelContext.save()
                    }
                    reload()
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(i18n.t(.sshAlwaysCompatibility))
                        .font(.system(size: 12, weight: .medium))
                    Text(i18n.t(.sshAlwaysCompatibilityDesc))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Divider()

            if profiles.isEmpty {
                Text(i18n.t(.sshNoProfile))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let display = showAll ? profiles : Array(profiles.prefix(1))
                ForEach(display, id: \.id) { profile in
                    profileCard(profile)
                }
                if profiles.count > 1 {
                    Button(showAll ? "Show less" : "Show all (\(profiles.count))") {
                        showAll.toggle()
                    }
                    .font(.system(size: 11))
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
                    .frame(width: 7, height: 7)
                Text(profile.backendRaw == SSHBackendType.native.rawValue
                    ? i18n.t(.sshBackendNative)
                    : i18n.t(.sshBackendCompatibility))
                    .font(.system(size: 11, weight: .semibold))
                Text("· \(profile.reasonRaw)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(profile.isPolicyReason ? i18n.t(.sshPolicyNoExpiry)
                    : (profile.isValid ? i18n.t(.sshProfileValid) : i18n.t(.sshProfileExpired)))
                    .font(.system(size: 10))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(profile.isPolicyReason ? Color.blue.opacity(0.15) : (profile.isValid ? Color.green.opacity(0.15) : Color.orange.opacity(0.15)))
                    .clipShape(Capsule())
            }

            // Auth + route
            Text("\(profile.authMethodRaw) · \(profile.host):\(profile.port)\(routeSummary(profile))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            // Timestamps
            HStack(spacing: 12) {
                Label(dateString(profile.detectedAt), systemImage: "clock")
                if !profile.isPolicyReason {
                    Label(dateString(profile.expiresAt), systemImage: "hourglass")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            // Algorithms
            let algos = profile.algorithmRequirements
            if let algo = algos, !algo.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(i18n.t(.sshAlgorithms)).font(.system(size: 10, weight: .medium))
                    if !algo.kex.isEmpty { Text("KEX: \(algo.kex.joined(separator: ", "))").font(.system(size: 10, design: .monospaced)) }
                    if !algo.hostKey.isEmpty { Text("HostKey: \(algo.hostKey.joined(separator: ", "))").font(.system(size: 10, design: .monospaced)) }
                    if !algo.cipher.isEmpty { Text("Cipher: \(algo.cipher.joined(separator: ", "))").font(.system(size: 10, design: .monospaced)) }
                    if !algo.mac.isEmpty { Text("MAC: \(algo.mac.joined(separator: ", "))").font(.system(size: 10, design: .monospaced)) }
                }
                .foregroundStyle(.secondary)
            }

            // Fingerprint
            if let citadelVer = profile.citadelVersion ?? profile.niosshVersion {
                Text("\(i18n.t(.sshFingerprint)): \(citadelVer) / \(profile.niosshVersion ?? "")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
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
