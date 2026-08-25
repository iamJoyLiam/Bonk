//
//  TeamLiveWindowView.swift
//  Bonk
//
//  Independent window for Team live terminal — mirrors SFTPWindow pattern.
//  Host's PTY is mirrored to guest via TeamRelay; guest views it here.
//  When not connected, shows placeholder with shortcut to Team sheet.
//

import SwiftUI

struct TeamLiveWindowView: View {
    @Environment(I18n.self) var i18n
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
    }
}
