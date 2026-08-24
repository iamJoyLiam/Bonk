//
//  ServerInfoPanel.swift
//  Bonk
//
//  Right sidebar: server system info + connection details + quick actions.
//

import SwiftUI

struct ServerInfoPanel: View {
    @Environment(I18n.self) var i18n
    let tab: TerminalTab?
    let onClose: () -> Void

    var body: some View {
        if let tab {
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        systemSection(tab)
                        Divider()
                        resourceSection(tab)
                    }
                    .padding(AppStyle.spacingXL)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            ContentUnavailableView(
                i18n.t(.disconnected),
                systemImage: "server.rack",
                description: Text(i18n.t(.selectHostInfo))
            )
        }
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(statusColor(activeState))
                .frame(width: AppStyle.statusDotMedium, height: AppStyle.statusDotMedium)
            Text(displayName)
                .font(.headline)
                .lineLimit(1)
            if let ipAddress = tab?.session?.serverInfo?.serverIP {
                Text(ipAddress)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: AppStyle.fontSmall, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(i18n.t(.close))
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingMPlus)
    }

    private var activeState: SSHConnectionState {
        tab?.session?.connectionState ?? .disconnected
    }

    private var displayName: String {
        tab?.session?.serverInfo?.hostname ?? tab?.hostItem.host ?? i18n.t(.serverInfo)
    }

    // MARK: - System Info

    private func systemSection(_ tab: TerminalTab) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(i18n.t(.systemInfo), systemImage: "desktopcomputer")
                .font(.headline)

            if let info = tab.session?.serverInfo {
                if let osName = info.os {
                    infoRow(i18n.t(.os)) { Text(osName) }
                }
                if let kernel = info.kernel {
                    infoRow(i18n.t(.kernel)) {
                        Text(kernel).font(.callout.monospaced())
                    }
                }
                if let arch = info.architecture {
                    infoRow(i18n.t(.arch)) { Text(arch) }
                }
                if let shell = info.shell {
                    infoRow(i18n.t(.shell)) {
                        Text(shell).font(.callout.monospaced())
                    }
                }
                if let seconds = info.uptimeSeconds {
                    infoRow(i18n.t(.uptime)) {
                        Text(formatUptime(seconds)).font(.callout.monospaced())
                    }
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
                .padding(.vertical, AppStyle.spacingM)
            }
        }
    }

    // MARK: - Resources

    private func resourceSection(_ tab: TerminalTab) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(i18n.t(.resources), systemImage: "chart.bar")
                .font(.headline)

            if let info = tab.session?.serverInfo {
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

                if let swapUsed = info.swapUsedBytes,
                   let swapTotal = info.swapTotalBytes,
                   swapTotal > 0
                {
                    infoRow(i18n.t(.swap)) {
                        Text("\(formatBytes(swapUsed))/\(formatBytes(swapTotal))")
                            .font(.callout.monospaced())
                    }
                }

                if let received = info.networkRXRateBps, let transmitted = info.networkTXRateBps {
                    infoRow(i18n.t(.network)) {
                        Text("↓ \(formatRate(received))  ↑ \(formatRate(transmitted))")
                            .font(.callout.monospaced())
                    }
                }

                if let read = info.diskReadRateBps, let write = info.diskWriteRateBps {
                    infoRow(i18n.t(.diskIO)) {
                        Text("R \(formatRate(read))  W \(formatRate(write))")
                            .font(.callout.monospaced())
                    }
                }

                if let temp = info.cpuTempCelsius {
                    infoRow(i18n.t(.cpuTemp)) {
                        Text("\(Int(temp.rounded()))°C").font(.callout.monospaced())
                    }
                }

                if let procs = info.topProcesses, !procs.isEmpty {
                    infoRow(i18n.t(.topProcesses)) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(parseProcesses(procs), id: \.self) { proc in
                                Text(proc).font(.caption.monospaced())
                            }
                        }
                    }
                }

                if let ports = info.listenPorts, !ports.isEmpty {
                    infoRow(i18n.t(.listenPorts)) {
                        Text(ports.trimmingCharacters(in: CharacterSet(charactersIn: ",")))
                            .font(.caption.monospaced())
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func infoRow(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12) {
            GridRow {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                value()
                    .font(.callout)
                    .gridColumnAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func formatUptime(_ seconds: UInt64) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1fG", Double(bytes) / 1_073_741_824)
        }
        return "\(bytes / 1_048_576)M"
    }

    private func formatRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
        if bytesPerSecond >= 1_000 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

    private func statusColor(_ state: SSHConnectionState) -> Color {
        switch state {
        case .connected: .green
        case .connecting, .reconnecting: .yellow
        case .disconnected: .red
        }
    }

    private func parseProcesses(_ raw: String) -> [String] {
        raw.split(separator: ";").map { entry in
            let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return String(entry) }
            return "\(parts[0])% \(parts[1])"
        }
    }
}
