//
//  JumpHostView.swift
//  Bonk
//

import SwiftData
import SwiftUI

/// Jump host management panel.
struct JumpHostView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \JumpHost.sortOrder) private var jumpHosts: [JumpHost]
    @Binding var isPresented: Bool

    @State private var showAddSheet = false
    @State private var editingHost: JumpHost?
    @State private var jumpHostService = JumpHostService.shared
    @State private var testingHostID: UUID?
    @State private var testResult: Bool?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "arrow.triangle.swap")
                    .foregroundStyle(.blue)
                Text(i18n.t(.jumpHosts))
                    .font(.headline)
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help(i18n.t(.addJumpHost))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Hosts list
            if jumpHosts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(i18n.t(.noJumpHosts))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(i18n.t(.jumpHostHint))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(jumpHosts) { host in
                            hostRow(host)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .sheet(isPresented: $showAddSheet) {
            JumpHostEditSheet(host: nil, modelContext: modelContext)
                .environment(i18n)
        }
        .sheet(item: $editingHost) { host in
            JumpHostEditSheet(host: host, modelContext: modelContext)
                .environment(i18n)
        }
    }

    @ViewBuilder
    private func hostRow(_ host: JumpHost) -> some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 14))
                .foregroundStyle(.blue)
                .frame(width: 20)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.system(size: 13, weight: .medium))
                Text(host.displayString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Edit button
            Button {
                editingHost = host
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                editingHost = host
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                testConnection(host)
            } label: {
                Label(i18n.t(.testConnection), systemImage: "network")
            }
            .disabled(testingHostID == host.id)
            Divider()
            Button(role: .destructive) {
                modelContext.delete(host)
            } label: {
                Label(i18n.t(.delete), systemImage: "trash")
            }
        }
    }

    private func testConnection(_ host: JumpHost) {
        testingHostID = host.id
        testResult = nil

        Task {
            // 使用密码认证进行测试
            let credential = SSHAuthMethod.password("test")
            let result = try? await jumpHostService.testConnection(
                jumpHost: host,
                credential: credential
            )
            await MainActor.run {
                testResult = result
                testingHostID = nil
            }
        }
    }
}

// MARK: - Jump Host Edit Sheet

struct JumpHostEditSheet: View {
    @Environment(I18n.self) var i18n
    @Environment(\.dismiss) private var dismiss
    let host: JumpHost?
    let modelContext: ModelContext

    @State private var name = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(i18n.t(.name)) {
                    TextField(i18n.t(.name), text: $name)
                }

                Section(i18n.t(.host)) {
                    TextField(i18n.t(.hostname), text: $hostname)
                    TextField(i18n.t(.port), text: $port)
                        .font(.system(size: 13, design: .monospaced))
                }

                Section(i18n.t(.username)) {
                    TextField(i18n.t(.username), text: $username)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(host == nil ? i18n.t(.addJumpHost) : i18n.t(.editJumpHost))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(i18n.t(.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(i18n.t(.save)) {
                        save()
                        dismiss()
                    }
                    .disabled(name.isEmpty || hostname.isEmpty || username.isEmpty)
                }
            }
            .onAppear {
                if let host {
                    name = host.name
                    hostname = host.host
                    port = "\(host.port)"
                    username = host.username
                }
            }
        }
        .frame(width: 480, height: 360)
    }

    private func save() {
        let portInt = Int(port) ?? 22

        if let host {
            host.name = name
            host.host = hostname
            host.port = portInt
            host.username = username
        } else {
            let newHost = JumpHost(
                name: name,
                host: hostname,
                port: portInt,
                username: username
            )
            modelContext.insert(newHost)
        }
    }
}
