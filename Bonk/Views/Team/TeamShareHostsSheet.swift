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
                        ForEach(allHosts) { hostItem in
                            HStack {
                                Image(systemName: selectedIDs.contains(hostItem.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIDs.contains(hostItem.id) ? .blue : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hostItem.name).lineLimit(1)
                                    Text("\(hostItem.username)@\(hostItem.host):\(hostItem.port)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedIDs.contains(hostItem.id) { selectedIDs.remove(hostItem.id) } else { selectedIDs.insert(hostItem.id) }
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
        let exports: [HostItemExport] = hosts.compactMap { hostItem in
            var credentialExport: CredentialExport?
            if let credential = hostItem.credentialRef {
                if credential.type == .apiKey { return nil } // skip apiKey
                // SecureEnclave cannot be exported
                if hostItem.authType == .secureEnclave || credential.type == .privateKey && hostItem.loadPrivateKey() == nil {
                    // still allow host without secret
                }
                var secretValue: String? = nil
                if includeSecrets {
                    if let credentialForSecret = hostItem.credentialRef, let loadedSecret = credentialForSecret.loadSecret(), !loadedSecret.isEmpty {
                        secretValue = loadedSecret
                    } else if hostItem.authType == .password, let loadedSecret = hostItem.loadPassword() {
                        secretValue = loadedSecret
                    } else if hostItem.authType == .privateKey, let loadedSecret = hostItem.loadPrivateKey() {
                        secretValue = loadedSecret
                    }
                    // SecureEnclave tag is not a secret, skip
                    if hostItem.authType == .secureEnclave { secretValue = nil }
                }
                credentialExport = CredentialExport(name: credential.name, type: credential.type.rawValue, username: credential.username, secret: secretValue)
            } else if includeSecrets {
                var secretValue: String? = nil
                if hostItem.authType == .password { secretValue = hostItem.loadPassword() }
                else if hostItem.authType == .privateKey { secretValue = hostItem.loadPrivateKey() }
                if let unwrappedSecret = secretValue, !unwrappedSecret.isEmpty {
                    credentialExport = CredentialExport(name: hostItem.name, type: hostItem.authType.rawValue, username: hostItem.username, secret: unwrappedSecret)
                }
            }
            return HostItemExport(name: hostItem.name, host: hostItem.host, port: hostItem.port, username: hostItem.username, authType: hostItem.authType.rawValue, credential: credentialExport)
        }
        relay.shareHosts(exports)
        dismiss()
    }
}
