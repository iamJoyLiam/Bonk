import SwiftUI
import SwiftData

struct TeamShareHostsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var allHosts: [HostItem]
    @ObservedObject var relay: TeamRelay
    @State private var selectedIDs = Set<UUID>()
    @State private var includeSecrets = false

    var body: some View {
        NavigationStack {
            Form {
                Section("选择要分享的主机") {
                    if allHosts.isEmpty {
                        Text("暂无已保存主机")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(allHosts) { host in
                            HStack {
                                Image(systemName: selectedIDs.contains(host.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIDs.contains(host.id) ? .blue : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.name).lineLimit(1)
                                    Text("\(host.username)@\(host.host):\(host.port)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedIDs.contains(host.id) { selectedIDs.remove(host.id) } else { selectedIDs.insert(host.id) }
                            }
                        }
                    }
                }
                Section("选项") {
                    Toggle("包含密码/私钥", isOn: $includeSecrets)
                    Text("包含敏感信息时请确认接收方为可信好友。SecureEnclave 凭证不支持导出。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Spacer()
                        Button("分享给访客") {
                            share()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedIDs.isEmpty)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("分享主机")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .frame(minWidth: 480, minHeight: 400)
    }

    private func share() {
        let hosts = allHosts.filter { selectedIDs.contains($0.id) }
        let exports: [HostItemExport] = hosts.compactMap { h in
            var credExport: CredentialExport?
            if let cred = h.credentialRef {
                if cred.type == .apiKey { return nil } // skip apiKey
                // SecureEnclave cannot be exported
                if h.authType == .secureEnclave || cred.type == .privateKey && h.loadPrivateKey() == nil {
                    // still allow host without secret
                }
                var secret: String? = nil
                if includeSecrets {
                    if let c = h.credentialRef, let s = c.loadSecret(), !s.isEmpty {
                        secret = s
                    } else if h.authType == .password, let s = h.loadPassword() {
                        secret = s
                    } else if h.authType == .privateKey, let s = h.loadPrivateKey() {
                        secret = s
                    }
                    // SecureEnclave tag is not a secret, skip
                    if h.authType == .secureEnclave { secret = nil }
                }
                credExport = CredentialExport(name: cred.name, type: cred.type.rawValue, username: cred.username, secret: secret)
            } else if includeSecrets {
                var secret: String? = nil
                if h.authType == .password { secret = h.loadPassword() }
                else if h.authType == .privateKey { secret = h.loadPrivateKey() }
                if let s = secret, !s.isEmpty {
                    credExport = CredentialExport(name: h.name, type: h.authType.rawValue, username: h.username, secret: s)
                }
            }
            return HostItemExport(name: h.name, host: h.host, port: h.port, username: h.username, authType: h.authType.rawValue, credential: credExport)
        }
        relay.shareHosts(exports)
        dismiss()
    }
}
