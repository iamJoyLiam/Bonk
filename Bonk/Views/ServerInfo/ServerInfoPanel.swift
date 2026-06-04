//
//  ServerInfoPanel.swift
//  Bonk
//
//  Right sidebar: server system info + connection details + quick actions.
//

import SwiftUI

struct ServerInfoPanel: View {
    @EnvironmentObject var i18n: I18n
    let tab: TerminalTab?
    let onDisconnect: () -> Void
    let onReconnect: () -> Void

    var body: some View {
        if let tab {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    connectionSection(tab)
                    Divider()
                    systemSection(tab)
                    Divider()
                    resourceSection(tab)
                    Divider()
                    actionsSection(tab)
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView(
                i18n.t(.disconnected),
                systemImage: "server.rack",
                description: Text(i18n.t(.selectHostInfo))
            )
        }
    }

    // MARK: - Connection

    @ViewBuilder
    private func connectionSection(_ tab: TerminalTab) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(i18n.t(.connection), systemImage: "bolt.fill")
                .font(.headline)

            infoRow(i18n.t(.status)) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor(tab.connectionState))
                        .frame(width: 8, height: 8)
                    Text(statusText(tab.connectionState))
                }
            }

            infoRow(i18n.t(.host)) {
                Text("\(tab.hostItem.host):\(tab.hostItem.port)")
                    .font(.body.monospaced())
            }

            infoRow(i18n.t(.username)) {
                Text(tab.hostItem.username)
                    .font(.body.monospaced())
            }

            if let connectedAt = tab.connectedAt {
                infoRow(i18n.t(.connected)) {
                    Text(connectedAt, style: .relative)
                }
            }

            if let ip = tab.serverInfo?.serverIP {
                infoRow(i18n.t(.serverIP)) {
                    Text(ip).font(.body.monospaced())
                }
            }

            if let error = tab.errorMessage {
                infoRow(i18n.t(.error)) {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(3)
                }
            }
        }
    }

    // MARK: - System Info

    @ViewBuilder
    private func systemSection(_ tab: TerminalTab) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(i18n.t(.systemInfo), systemImage: "desktopcomputer")
                .font(.headline)

            if let info = tab.serverInfo {
                if let os = info.os {
                    infoRow(i18n.t(.os)) { Text(os) }
                }
                if let kernel = info.kernel {
                    infoRow(i18n.t(.kernel)) {
                        Text(kernel).font(.callout.monospaced())
                    }
                }
                if let arch = info.architecture {
                    infoRow(i18n.t(.arch)) { Text(arch) }
                }
                if let hostname = info.hostname {
                    infoRow(i18n.t(.hostname)) {
                        Text(hostname).font(.callout.monospaced())
                    }
                }
                if let shell = info.shell {
                    infoRow(i18n.t(.shell)) {
                        Text(shell).font(.callout.monospaced())
                    }
                }
                if let uptime = info.uptime {
                    infoRow(i18n.t(.uptime)) { Text(uptime) }
                }
                if let cpu = info.cpuModel {
                    infoRow(i18n.t(.cpu)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cpu).font(.callout)
                            if let cores = info.cpuCores {
                                Text("\(cores) cores")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text(i18n.t(.fetching))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Resources

    @ViewBuilder
    private func resourceSection(_ tab: TerminalTab) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(i18n.t(.resources), systemImage: "chart.bar")
                .font(.headline)

            if let info = tab.serverInfo {
                // Memory (format: "used/total")
                if let mem = info.memoryUsed {
                    infoRow(i18n.t(.memory)) {
                        Text(mem).font(.callout.monospaced())
                    }
                }

                // Disk (format: "used/total")
                if let disk = info.diskUsed {
                    infoRow(i18n.t(.disk)) {
                        Text(disk).font(.callout.monospaced())
                    }
                }

                // Load Average
                if let load = info.loadAverage {
                    infoRow(i18n.t(.loadAvg)) {
                        Text(load).font(.callout.monospaced())
                    }
                }
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actionsSection(_ tab: TerminalTab) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(i18n.t(.actions), systemImage: "bolt.circle")
                .font(.headline)

            switch tab.connectionState {
            case .connected:
                Button { onDisconnect() } label: {
                    Label(i18n.t(.disconnect), systemImage: "bolt.slash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

            case .disconnected:
                Button { onReconnect() } label: {
                    Label(i18n.t(.connect), systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)

            case .connecting, .reconnecting:
                Button(role: .destructive) { onDisconnect() } label: {
                    Label(i18n.t(.cancel), systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Helpers

    private func infoRow<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            value()
                .font(.callout)
            Spacer()
        }
    }

    private func statusColor(_ state: SSHConnectionState) -> Color {
        switch state {
        case .connected: .green
        case .connecting, .reconnecting: .yellow
        case .disconnected: .red
        }
    }

    private func statusText(_ state: SSHConnectionState) -> String {
        let i18n = self.i18n
        switch state {
        case .disconnected: return i18n.t(.disconnected)
        case .connecting: return i18n.t(.connectingTo)
        case .connected: return i18n.t(.connected)
        case .reconnecting(let a, let m): return String(format: i18n.t(.reconnecting), a, m)
        }
    }
}
