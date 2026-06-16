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

    @Bindable var sessionManager: SessionManager
    let defaultPort: Int

    @State private var showAddSheet = false
    @State private var editingHost: HostItem?
    @State private var showKeychain = false
    @State private var searchText = ""
    @State private var pendingDeleteHost: HostItem?

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
        return grouped.sorted { $0.key < $1.key }
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
                            hostRow(host, groupColor: groupModel(for: groupName)?.resolvedColor)
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
                    .font(.system(size: 11))

                TextField(i18n.t(.search), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                    .frame(height: 14)

                Button {
                    showKeychain = true
                } label: {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help(i18n.t(.manageCredentials))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(.quaternary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showKeychain) {
            NavigationStack {
                KeychainManagerView()
                    .modelContext(modelContext)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showAddSheet = true
                } label: {
                    Label(i18n.t(.addHost), systemImage: "plus")
                }
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
            NavigationStack {
                AddHostSheet(existingHost: host, defaultPort: defaultPort) { _ in }
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
                    .font(.system(size: 10))
                    .foregroundStyle(group?.resolvedColor ?? .secondary)
            }
            Text(groupName)
        }
    }

    // MARK: - Host Row

    @ViewBuilder
    // swiftlint:disable:next function_body_length
    private func hostRow(_ host: HostItem, groupColor: Color? = nil) -> some View {
        let tab = sessionManager.tabs.first(where: { $0.hostItem.id == host.id })
        let state = tab?.session?.connectionState ?? .disconnected

        Button {
            if let tab {
                sessionManager.selectTab(tab.id)
            } else {
                sessionManager.openTab(for: host)
            }
        } label: {
            HStack(spacing: 10) {
                // Group color indicator
                if let color = groupColor {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: 3, height: 16)
                }

                statusDot(state)

                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name)
                        .font(.body)
                        .lineLimit(1)

                    Text("\(host.username)@\(host.host):\(host.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if tab != nil {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .onTapGesture {
                            if let tabID = tab?.id {
                                Task { await sessionManager.closeTab(tabID) }
                            }
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                if let tab {
                    sessionManager.selectTab(tab.id)
                } else {
                    sessionManager.openTab(for: host)
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

    @ViewBuilder
    private func statusDot(_ state: SSHConnectionState) -> some View {
        let color: Color = switch state {
        case .connected: .green
        case .connecting, .reconnecting: .yellow
        case .disconnected: .gray
        }
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}
