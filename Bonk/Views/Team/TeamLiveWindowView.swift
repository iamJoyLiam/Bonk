//
//  TeamLiveWindowView.swift
//  Bonk
//
//  Independent window for Team live terminal — mirrors SFTPWindow pattern.
//  Host's PTY is mirrored to guest via TeamRelay; guest views it here.
//  When not connected, shows placeholder with shortcut to Team sheet.
//

import SwiftUI
import SwiftData

struct TeamLiveWindowView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var relay: TeamRelay
    @Environment(WorkspaceManager.self) var workspace

    var body: some View {
        Group {
            if relay.isConnected {
                TeamGuestTerminalView(relay: relay)
            } else {
                ContentUnavailableView(
                    i18n.t(.disconnected),
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("未连接到主持端。请先通过 “团队” 加入会话，连接成功后实时终端将在此窗口显示。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    NotificationCenter.default.post(name: Notification.Name("BonkShowTeam"), object: nil)
                } label: {
                    Label(i18n.t(.team), systemImage: "person.2.fill")
                }
                .help(i18n.t(.team))
            }
        }
        .alert(
            "控制权已收回",
            isPresented: Binding(
                get: { relay.controlRevokedNotice != nil },
                set: { if !$0 { relay.controlRevokedNotice = nil } }
            )
        ) {
            Button("知道了") { relay.controlRevokedNotice = nil }
        } message: {
            Text(relay.controlRevokedNotice ?? "主持人已收回控制权")
        }
        .alert(
            "连接已断开",
            isPresented: Binding(
                get: { relay.peerDisconnectedNotice != nil },
                set: { if !$0 { relay.peerDisconnectedNotice = nil } }
            )
        ) {
            Button("知道了") { relay.peerDisconnectedNotice = nil }
        } message: {
            Text(relay.peerDisconnectedNotice ?? "")
        }
        .alert(
            i18n.t(.connectionError),
            isPresented: Binding(
                get: {
                    guard relay.lastError != nil else { return false }
                    return !relay.isConnected && !relay.isHosting
                },
                set: { if !$0 { relay.lastError = nil } }
            )
        ) {
            Button(i18n.t(.ok)) { relay.lastError = nil }
        } message: {
            Text(relay.lastError ?? "")
        }
        .alert(
            "收到共享主机",
            isPresented: Binding(
                get: { relay.pendingShareHosts != nil },
                set: { if !$0 { relay.pendingShareHosts = nil } }
            )
        ) {
            Button("合并") {
                if let hosts = relay.pendingShareHosts {
                    Task { await importSharedHosts(hosts) }
                    relay.pendingShareHosts = nil
                }
            }
            Button("取消", role: .cancel) { relay.pendingShareHosts = nil }
        } message: {
            if let hosts = relay.pendingShareHosts {
                Text("主持人分享了 \(hosts.count) 台主机：\(hosts.map(\.name).joined(separator: "、"))，是否合并到本地？")
            }
        }
    }

    private func importSharedHosts(_ hosts: [HostItemExport]) async {
        for exp in hosts {
            let exists = (try? modelContext.fetch(FetchDescriptor<HostItem>()))?.contains(where: { $0.host == exp.host && $0.port == exp.port && $0.username == exp.username }) ?? false
            if exists { continue }
            let authType = AuthType(rawValue: exp.authType) ?? .password
            let host = HostItem(name: exp.name, host: exp.host, port: exp.port, username: exp.username, authType: authType)
            if let credExp = exp.credential, let secret = credExp.secret, !secret.isEmpty {
                if authType != .secureEnclave {
                    let type: CredentialType = CredentialType(rawValue: credExp.type) ?? .password
                    if type != .apiKey {
                        let cred = Credential(name: credExp.name, type: type, username: credExp.username)
                        cred.storeSecret(secret)
                        modelContext.insert(cred)
                        host.credentialRef = cred
                    }
                }
            }
            modelContext.insert(host)
        }
        try? modelContext.save()
    }
}
