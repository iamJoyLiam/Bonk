//
//  PortForwardView.swift
//  Bonk
//
//  Port forwarding management — uses Form+Section (not List inside Form).
//

import SwiftData
import SwiftUI

/// Port forwarding management panel.
struct PortForwardView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PortForward.createdAt) private var rules: [PortForward]
    @Binding var isPresented: Bool
    let sshService: SSHNetworkService?

    @State private var showAddSheet = false
    @State private var editingRule: PortForward?
    @State private var portForwardService = PortForwardService.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.blue)
                Text(i18n.t(.portForwarding))
                    .font(.headline)
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help(i18n.t(.addPortForward))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Rules list
            if rules.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(i18n.t(.noPortForwards))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section {
                        ForEach(rules) { rule in
                            ruleRow(rule)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .sheet(isPresented: $showAddSheet) {
            PortForwardEditSheet(rule: nil, modelContext: modelContext)
                .environment(i18n)
        }
        .sheet(item: $editingRule) { rule in
            PortForwardEditSheet(rule: rule, modelContext: modelContext)
                .environment(i18n)
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: PortForward) -> some View {
        HStack(spacing: 12) {
            // Type icon
            Image(systemName: rule.type == .local ? "arrow.right" : "arrow.left")
                .font(.system(size: 14))
                .foregroundStyle(rule.isActive ? .green : .secondary)
                .frame(width: 20)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.system(size: 13, weight: .medium))
                Text(rule.displayDescription)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Type badge
            Text(rule.type.displayName)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Capsule())

            // Toggle
            Button {
                toggleForward(rule)
            } label: {
                Image(systemName: rule.isActive ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(rule.isActive ? .red : .green)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                editingRule = rule
            } label: {
                Label(i18n.t(.edit), systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                modelContext.delete(rule)
            } label: {
                Label(i18n.t(.delete), systemImage: "trash")
            }
        }
    }

    private func toggleForward(_ rule: PortForward) {
        Task {
            if rule.isActive {
                await portForwardService.stop(config: rule)
            } else {
                do {
                    try await portForwardService.start(config: rule)
                } catch {
                    // Handle error
                    print("Port forward error: \(error)")
                }
            }
        }
    }
}

// MARK: - Port Forward Edit Sheet

struct PortForwardEditSheet: View {
    @Environment(I18n.self) var i18n
    @Environment(\.dismiss) private var dismiss
    let rule: PortForward?
    let modelContext: ModelContext

    @State private var name = ""
    @State private var type: PortForward.ForwardType = .local
    @State private var localHost = "127.0.0.1"
    @State private var localPort = ""
    @State private var remoteHost = "127.0.0.1"
    @State private var remotePort = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(i18n.t(.name)) {
                    TextField(i18n.t(.name), text: $name)
                }

                Section(i18n.t(.type)) {
                    Picker(i18n.t(.type), selection: $type) {
                        ForEach(PortForward.ForwardType.allCases, id: \.self) { forwardType in
                            Text(forwardType.displayName).tag(forwardType)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(i18n.t(.local)) {
                    TextField(i18n.t(.host), text: $localHost)
                    TextField(i18n.t(.port), text: $localPort)
                        .font(.system(size: 13, design: .monospaced))
                }

                Section(i18n.t(.remote)) {
                    TextField(i18n.t(.host), text: $remoteHost)
                    TextField(i18n.t(.port), text: $remotePort)
                        .font(.system(size: 13, design: .monospaced))
                }
                .disabled(type == .dynamic)
            }
            .formStyle(.grouped)
            .navigationTitle(rule == nil ? i18n.t(.addPortForward) : i18n.t(.editPortForward))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(i18n.t(.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(i18n.t(.save)) {
                        save()
                        dismiss()
                    }
                    .disabled(name.isEmpty || localPort.isEmpty)
                }
            }
            .onAppear {
                if let rule {
                    name = rule.name
                    type = rule.type
                    localHost = rule.localHost
                    localPort = "\(rule.localPort)"
                    remoteHost = rule.remoteHost
                    remotePort = "\(rule.remotePort)"
                }
            }
        }
        .frame(width: 480, height: 440)
    }

    private func save() {
        let localPortInt = Int(localPort) ?? 0
        let remotePortInt = Int(remotePort) ?? 0

        if let rule {
            rule.name = name
            rule.typeRaw = type.rawValue
            rule.localHost = localHost
            rule.localPort = localPortInt
            rule.remoteHost = remoteHost
            rule.remotePort = remotePortInt
        } else {
            let newRule = PortForward(
                name: name,
                type: type,
                localHost: localHost,
                localPort: localPortInt,
                remoteHost: remoteHost,
                remotePort: remotePortInt
            )
            modelContext.insert(newRule)
        }
    }
}
