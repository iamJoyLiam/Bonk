//
//  PortForwardView.swift
//  Bonk
//
//  Port forwarding management — uses Form+Section (not List inside Form).
//

import os.log
import SwiftData
import SwiftUI

/// Port forwarding management panel.
struct PortForwardView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PortForward.createdAt) private var rules: [PortForward]
    @Binding var isPresented: Bool
    let sshService: SSHNetworkService?
    var session: TerminalSession? // v3.3 Native prefers session (has vnextSession)

    @State private var showAddSheet = false
    @State private var editingRule: PortForward?
    @State private var portForwardService = PortForwardService.shared

    @State private var hoveredRuleID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeaderView(
                icon: "arrow.triangle.branch",
                title: i18n.t(.portForwarding),
                count: rules.isEmpty ? nil : rules.count,
                trailing: AnyView(
                    PanelAddButton(help: i18n.t(.addPortForward)) { showAddSheet = true }
                )
            )
            Divider()
            if rules.isEmpty {
                PanelEmptyView(
                    icon: "arrow.triangle.branch",
                    title: i18n.t(.noPortForwards),
                    hint: nil
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: AppStyle.spacingS) {
                        ForEach(rules) { rule in ruleRow(rule) }
                    }
                    .padding(AppStyle.spacingL)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showAddSheet) {
            PortForwardEditSheet(rule: nil, modelContext: modelContext)
                .environment(i18n)
        }
        .sheet(item: $editingRule) { rule in
            PortForwardEditSheet(rule: rule, modelContext: modelContext)
                .environment(i18n)
        }
    }

    private func ruleRow(_ rule: PortForward) -> some View {
        let isHovered = hoveredRuleID == rule.id
        return HStack(spacing: AppStyle.spacingL) {
            Image(systemName: rule.type == .local ? "arrow.right" : "arrow.left")
                .font(.system(size: AppStyle.fontMedium, weight: .medium))
                .foregroundStyle(rule.isActive ? .green : .secondary)
                .frame(width: AppStyle.buttonLarge, height: AppStyle.buttonLarge)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.system(size: AppStyle.fontRegular, weight: .medium))
                    .lineLimit(1)
                Text(rule.displayDescription)
                    .font(.system(size: AppStyle.fontSmall, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AppStyle.spacingM)
            Text(rule.type.displayName)
                .font(.system(size: AppStyle.fontCaption, weight: .medium))
                .padding(.horizontal, AppStyle.spacingS)
                .padding(.vertical, AppStyle.spacingXXS)
                .background(Color.accentColor.opacity(AppStyle.opacityBackgroundLight))
                .clipShape(Capsule())
            Button { toggleForward(rule) } label: {
                Image(systemName: rule.isActive ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: AppStyle.fontSubtitle))
                    .foregroundStyle(rule.isActive ? .red : .green)
                    .frame(width: AppStyle.buttonMedium, height: AppStyle.buttonMedium)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(AppStyle.opacityStroke), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(rule.isActive ? i18n.t(.stop) : i18n.t(.run))
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingML)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous))
        .shadow(color: Color.black.opacity(isHovered ? 0.07 : 0.03), radius: isHovered ? 8 : 4, y: isHovered ? 3 : 1)
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovered ? 0.08 : 0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hoveredRuleID = h ? rule.id : nil }
        }
        .onTapGesture { editingRule = rule }
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
                portForwardService.stop(config: rule)
            } else {
                do {
                    if let session {
                        try await portForwardService.start(config: rule, using: session)
                    } else {
                        try await portForwardService.start(config: rule, using: sshService)
                    }
                } catch {
                    Log.ssh.error("Port forward error: \(error.localizedDescription)")
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
                        .font(.system(size: AppStyle.fontRegular, design: .monospaced))
                }

                Section(i18n.t(.remote)) {
                    TextField(i18n.t(.host), text: $remoteHost)
                    TextField(i18n.t(.port), text: $remotePort)
                        .font(.system(size: AppStyle.fontRegular, design: .monospaced))
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
        .frame(width: AppStyle.dialogWidth, height: 440)
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
