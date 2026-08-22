//
//  QuickConnectView.swift
//  Bonk
//
//  Quick connect sheet with search and recent connections.
//

import SwiftData
import SwiftUI

struct QuickConnectView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \HostItem.lastConnectedAt, order: .reverse) private var allHosts: [HostItem]

    @Bindable var sessionManager: SessionManager
    @Binding var isPresented: Bool
    let defaultPort: Int

    @State private var searchText = ""
    @State private var showAddHost = false
    @State private var selectedIndex = 0

    private var recentHosts: [HostItem] {
        allHosts
            .filter { $0.lastConnectedAt != nil }
            .prefix(10)
            .map { $0 }
    }

    private var filteredHosts: [HostItem] {
        if searchText.isEmpty {
            return []
        }
        return allHosts.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.host.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(i18n.t(.searchHosts), text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        if !searchText.isEmpty {
                            if filteredHosts.isEmpty {
                                // Search not found, show add host
                                showAddHost = true
                            } else if selectedIndex < filteredHosts.count {
                                // Connect to selected host
                                connectToHost(filteredHosts[selectedIndex])
                            }
                        }
                    }
                    .onChange(of: searchText) { _, _ in
                        selectedIndex = 0
                    }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(AppStyle.spacingL)

            Divider()

            // Content
            ScrollView {
                VStack(spacing: 0) {
                    // Search results
                    if !searchText.isEmpty {
                        if filteredHosts.isEmpty {
                            // No results - show add host option
                            Button {
                                showAddHost = true
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(.blue)
                                    Text("\(i18n.t(.connectTo)) \(searchText)")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(i18n.t(.enter))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, AppStyle.spacingXL)
                                .padding(.vertical, AppStyle.spacingL)
                            }
                            .buttonStyle(.plain)
                        } else {
                            // Show search results
                            ForEach(Array(filteredHosts.enumerated()), id: \.element.id) { index, host in
                                hostRow(host, isSelected: index == selectedIndex)
                                    .id(host.id)
                                    .onTapGesture {
                                        connectToHost(host)
                                    }
                            }
                        }
                    }

                    // Recent hosts (when no search)
                    if searchText.isEmpty, !recentHosts.isEmpty {
                        sectionHeaderView(title: i18n.t(.recent))
                        ForEach(recentHosts) { host in
                            hostRow(host, isSelected: false)
                                .id(host.id)
                                .onTapGesture {
                                    connectToHost(host)
                                }
                        }
                    }

                    // All hosts (when no search)
                    if searchText.isEmpty {
                        sectionHeaderView(title: i18n.t(.allHosts))
                        ForEach(allHosts) { host in
                            hostRow(host, isSelected: false)
                                .id(host.id)
                                .onTapGesture {
                                    connectToHost(host)
                                }
                        }
                    }
                }
            }
        }
        .frame(width: AppStyle.quickConnectWidth, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < filteredHosts.count - 1 {
                selectedIndex += 1
            }
            return .handled
        }
        .sheet(isPresented: $showAddHost) {
            NavigationStack {
                AddHostSheet(
                    defaultPort: defaultPort,
                    initialHost: searchText.isEmpty ? nil : searchText
                ) { host in
                    modelContext.insert(host)
                    sessionManager.openTab(for: host)
                    isPresented = false
                }
                .environment(i18n)
            }
        }
    }

    // MARK: - Host Row

    private func hostRow(_ host: HostItem, isSelected: Bool) -> some View {
        let isOpen = sessionManager.tabs.contains(where: { $0.hostItem.id == host.id })
        return HStack(spacing: 10) {
            Circle()
                .fill(isOpen ? Color.green : Color.secondary.opacity(AppStyle.opacityOverlay))
                .frame(width: AppStyle.statusDotMedium, height: AppStyle.statusDotMedium)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.system(size: AppStyle.fontRegular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(host.username)@\(host.host):\(host.port)")
                    .font(.system(size: AppStyle.fontSmall))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isOpen {
                Text(i18n.t(.connected))
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, AppStyle.spacingXL)
        .padding(.vertical, AppStyle.spacingML)
        .background(isSelected ? Color.accentColor.opacity(AppStyle.opacityOverlayLight) : Color.clear)
        .contentShape(Rectangle())
    }

    // MARK: - Section Header

    private func sectionHeaderView(title: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, AppStyle.spacingXL)
        .padding(.vertical, AppStyle.spacingM)
        .background(Color(nsColor: .controlBackgroundColor).opacity(AppStyle.opacityDisabled))
    }

    // MARK: - Actions

    private func connectToHost(_ host: HostItem) {
        let isOpen = sessionManager.tabs.contains(where: { $0.hostItem.id == host.id })
        if isOpen {
            if let tab = sessionManager.tabs.first(where: { $0.hostItem.id == host.id }) {
                sessionManager.selectTab(tab.id)
            }
        } else {
            sessionManager.openTab(for: host)
        }
        isPresented = false
    }
}
