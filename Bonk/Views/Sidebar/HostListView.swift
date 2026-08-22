//
//  HostListView.swift
//  Bonk
//
//  Created by Joy Liam on 2026/5/25.
//

import SwiftData
import SwiftUI

/// Left sidebar: list of saved SSH hosts with connection status.
struct HostListView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HostItem.createdAt) private var hosts: [HostItem]
    @Query(sort: \HostGroup.sortOrder) private var hostGroups: [HostGroup]
    @Query(sort: \SSHBackendProfile.detectedAt, order: .reverse) private var backendProfiles: [SSHBackendProfile]

    @Bindable var sessionManager: SessionManager
    let defaultPort: Int

    @State private var showAddSheet = false
    @State private var editingHost: HostItem?
    @State private var showKeychain = false
    @State private var searchText = ""
    @State private var pendingDeleteHost: HostItem?
    @State private var diagnosisHost: HostItem?

    private var filteredHosts: [HostItem] {
        if searchText.isEmpty { return hosts }
        return hosts.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.host.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var tabsByHostID: [UUID: TerminalTab] {
        // Use lastMatching to handle duplicate tabs for same host
        var result: [UUID: TerminalTab] = [:]
        for tab in sessionManager.tabs {
            result[tab.hostItem.id] = tab
        }
        return result
    }

    private var groupedHosts: [(String, [HostItem])] {
        let grouped = Dictionary(grouping: filteredHosts) { $0.groupRef?.name ?? i18n.t(.unGrouped) }
        let ungroupedName = i18n.t(.unGrouped)
        return grouped.sorted { lhs, rhs in
            if lhs.key == ungroupedName { return false }
            if rhs.key == ungroupedName { return true }
            let orderA = hostGroups.first(where: { $0.name == lhs.key })?.sortOrder ?? Int.max
            let orderB = hostGroups.first(where: { $0.name == rhs.key })?.sortOrder ?? Int.max
            return orderA < orderB
        }.map { key, hosts in
            (key, hosts.sorted { $0.sortOrder < $1.sortOrder })
        }
    }

    /// Look up HostGroup by name.
    private func groupModel(for name: String) -> HostGroup? {
        hostGroups.first(where: { $0.name == name })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Host list
            List(selection: $sessionManager.activeTabID) {
                ForEach(groupedHosts, id: \.0) { groupName, items in
                    Section {
                        ForEach(items) { host in
                            let tab = tabsByHostID[host.id]
                            hostRow(host, groupColor: groupModel(for: groupName)?.resolvedColor, tab: tab)
                                .tag(tab?.id as UUID?)
                        }
                        .onDelete { indexSet in
                            if let idx = indexSet.first { pendingDeleteHost = items[idx] }
                        }
                    } header: {
                        groupHeader(groupName)
                    }
                }
            }

            Divider()

            // Bottom: capsule search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: AppStyle.fontSmall))

                TextField(i18n.t(.search), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppStyle.fontBody))

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: AppStyle.fontSmall))
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                    .frame(height: AppStyle.iconXL)

                Button {
                    showKeychain = true
                } label: {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: AppStyle.fontSmall))
                }
                .buttonStyle(.plain)
                .help(i18n.t(.manageCredentials))
            }
            .padding(.horizontal, AppStyle.spacingML)
            .padding(.vertical, AppStyle.spacingS)
            .background {
                Capsule()
                    .fill(.quaternary.opacity(AppStyle.opacityDisabled))
            }
            .padding(.horizontal, AppStyle.spacingL)
            .padding(.vertical, AppStyle.spacingM)
        }
        .sheet(isPresented: $showKeychain) {
            NavigationStack {
                KeychainManagerView()
                    .modelContext(modelContext)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                AddHostSheet(defaultPort: defaultPort) { host in
                    modelContext.insert(host)
                }
            }
        }
        .sheet(item: $editingHost) { host in
            if host.isSerial == true {
                NavigationStack {
                    SerialPortEditSheet(host: host)
                        .environment(i18n)
                }
            } else {
                NavigationStack {
                    AddHostSheet(existingHost: host, defaultPort: defaultPort) { _ in }
                }
            }
        }
        .alert(i18n.t(.delete), isPresented: deleteHostAlertBinding) {
            Button(i18n.t(.delete), role: .destructive) {
                if let host = pendingDeleteHost {
                    host.deleteCredentials()
                    modelContext.delete(host)
                }
                pendingDeleteHost = nil
            }
            Button(i18n.t(.cancel), role: .cancel) { pendingDeleteHost = nil }
        } message: {
            if let host = pendingDeleteHost {
                Text(i18n.tr(.deleteConfirm, args: host.name))
            }
        }
        .sheet(item: $diagnosisHost) { host in
            NavigationStack {
                Form {
                    HostConnectionDiagnosisView(host: host)
                }
                .formStyle(.grouped)
                .navigationTitle(host.name)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(i18n.t(.done)) { diagnosisHost = nil }
                    }
                }
            }
            .frame(minWidth: 520, idealWidth: 560)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 520)
            .environment(i18n)
        }
    }

    private var deleteHostAlertBinding: Binding<Bool> {
        Binding(get: { pendingDeleteHost != nil }, set: { if !$0 { pendingDeleteHost = nil } })
    }

    // MARK: - Group Header

    @ViewBuilder
    private func groupHeader(_ groupName: String) -> some View {
        let group = groupModel(for: groupName)
        HStack(spacing: 4) {
            if let icon = group?.icon, !icon.isEmpty {
                Image(systemName: icon)
                    .font(.system(size: AppStyle.fontCaption))
                    .foregroundStyle(group?.resolvedColor ?? .secondary)
            }
            Text(groupName)
        }
    }

    // MARK: - Host Row

    @ViewBuilder
    // swiftlint:disable:next function_body_length
    private func hostRow(_ host: HostItem, groupColor: Color? = nil, tab: TerminalTab?) -> some View {
        let state = tab?.session?.connectionState ?? .disconnected

        Button {
            if let tab {
                sessionManager.selectTab(tab.id)
            } else {
                sessionManager.openHost(host)
            }
        } label: {
            HStack(spacing: 10) {
                // Group color indicator
                if let color = groupColor {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: AppStyle.indicatorMedium, height: 16)
                }

                if host.isSerial == true {
                    Image(systemName: "cable.connector")
                        .font(.system(size: AppStyle.fontBody))
                        .foregroundStyle(stateColor(state))
                } else {
                    statusDot(state)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(host.name)
                            .font(.system(size: AppStyle.fontRegular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                        Spacer(minLength: 4)
                        if host.isSerial != true {
                            inlineBackendBadge(for: host)
                        }
                    }
                    if host.isSerial == true {
                        Text("\(i18n.t(.serialPort)) · \(host.host)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                if let tab {
                    sessionManager.selectTab(tab.id)
                } else {
                    sessionManager.openHost(host)
                }
            } label: {
                Label(i18n.t(.connect), systemImage: "bolt.fill")
            }

            if tab != nil {
                Button {
                    if let id = tab?.id {
                        Task { await sessionManager.disconnectTab(id) }
                    }
                } label: {
                    Label(i18n.t(.disconnect), systemImage: "bolt.slash")
                }

                Button {
                    if let id = tab?.id {
                        Task { await sessionManager.reconnectTab(id) }
                    }
                } label: {
                    Label(i18n.t(.reconnect), systemImage: "arrow.clockwise")
                }
            }

            Divider()

            Menu {
                Button {
                    host.groupRef = nil
                } label: {
                    if host.groupRef == nil {
                        Label(i18n.t(.unGrouped), systemImage: "checkmark")
                    } else {
                        Text(i18n.t(.unGrouped))
                    }
                }
                ForEach(hostGroups) { group in
                    Button {
                        host.groupRef = group
                    } label: {
                        if host.groupRef?.id == group.id {
                            Label(group.name, systemImage: "checkmark")
                        } else {
                            Text(group.name)
                        }
                    }
                }
            } label: {
                Label(i18n.t(.moveToGroup), systemImage: "folder")
            }

            if host.isSerial != true {
                Button {
                    diagnosisHost = host
                } label: {
                    Label(i18n.t(.sshEngineDiagnosis), systemImage: "info.circle")
                }
            }

            Button {
                editingHost = host
            } label: {
                Label(i18n.t(.edit), systemImage: "pencil")
            }

            Button(role: .destructive) {
                pendingDeleteHost = host
            } label: {
                Label(i18n.t(.delete), systemImage: "trash")
            }
        }
    }

    private func statusDot(_ state: SSHConnectionState) -> some View {
        Circle()
            .fill(stateColor(state))
            .frame(width: AppStyle.statusDotMedium, height: AppStyle.statusDotMedium)
    }

    private func stateColor(_ state: SSHConnectionState) -> Color {
        switch state {
        case .connected: .green
        case .connecting, .reconnecting: .yellow
        case .disconnected: .gray
        }
    }

    // MARK: - Backend Badge (v3.2 routing visualization)

    private func latestProfile(for host: HostItem) -> SSHBackendProfile? {
        // Direct lookup: host+port; prefer valid, newest first (Query already sorted)
        for p in backendProfiles where p.host == host.host && p.port == host.port && p.isValid {
            return p
        }
        // Fallback: any profile for host (even if expired, show stale)
        return backendProfiles.first { $0.host == host.host && $0.port == host.port }
    }

    @ViewBuilder
    private func inlineBackendBadge(for host: HostItem) -> some View {
        if let profile = latestProfile(for: host) {
            let isNative = profile.backendRaw == SSHBackendType.native.rawValue
            let isExpired = !profile.isValid
            HStack(spacing: 3) {
                Circle()
                    .fill(isExpired ? Color.gray : (isNative ? Color.green : Color.orange))
                    .frame(width: AppStyle.statusDotTiny, height: AppStyle.statusDotTiny)
                Text(badgeText(for: profile, isNative: isNative))
                    .font(.system(size: AppStyle.fontTiny, weight: .medium, design: .monospaced))
                    .foregroundStyle(isExpired ? .secondary : (isNative ? Color.green : Color.orange))
                    .lineLimit(1)
            }
            .padding(.horizontal, AppStyle.spacingXS).padding(.vertical, AppStyle.spacingXXS)
            .background((isNative ? Color.green : Color.orange).opacity(isExpired ? 0.07 : 0.10))
            .clipShape(Capsule())
            .help(badgeHelp(for: profile))
        }
    }

    private func badgeText(for profile: SSHBackendProfile, isNative: Bool) -> String {
        // User wants yellow badge to say OpenSSH, not "兼容·强制"
        if !isNative {
            // All Compatibility shows as OpenSSH (yellow)
            if profile.reasonRaw == SSHBackendReason.forcedCompatibility.rawValue { return "OpenSSH" }
            if profile.reasonRaw == SSHBackendReason.jumpHost.rawValue { return "OpenSSH·Jump" }
            if profile.reasonRaw == SSHBackendReason.hostKeyMismatch.rawValue { return "OpenSSH" }
            // Keep short suffix for debug, but base is OpenSSH
            switch profile.reasonRaw {
            case SSHBackendReason.kexMismatch.rawValue: return "OpenSSH"
            case SSHBackendReason.cipherMismatch.rawValue: return "OpenSSH"
            case SSHBackendReason.noKbdInteractive.rawValue: return "OpenSSH"
            default: return "OpenSSH"
            }
        }
        return "Native"
    }

    private func badgeHelp(for profile: SSHBackendProfile) -> String {
        let backend = profile.backendRaw == SSHBackendType.native.rawValue ? "Native (SwiftNIO)" : "兼容 (OpenSSH)"
        return "\(backend) · \(profile.reasonRaw) · \(profile.isValid ? "有效" : "已过期")"
    }
}
