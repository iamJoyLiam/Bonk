//
//  TriggerSettingsView.swift
//  Bonk
//
//  Manage regex triggers → highlight / notify / sendText.
//

import SwiftData
import SwiftUI

struct TriggerSettingsView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TriggerRule.createdAt, order: .reverse) private var rules: [TriggerRule]
    @State private var showAddSheet = false
    @State private var editingRule: TriggerRule?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeaderView(
                icon: "bolt.trianglebadge.exclamationmark",
                title: i18n.t(.triggers),
                count: rules.isEmpty ? nil : rules.count,
                trailing: AnyView(
                    PanelAddButton(help: i18n.t(.addTrigger)) { showAddSheet = true }
                )
            )
            Divider()
            if rules.isEmpty {
                PanelEmptyView(
                    icon: "bolt.slash",
                    title: i18n.t(.noTriggers),
                    hint: i18n.t(.noTriggersDescription)
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rules) { rule in
                            triggerRow(rule)
                            if rule.id != rules.last?.id {
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showAddSheet) { TriggerEditSheet(rule: nil) }
        .sheet(item: $editingRule) { rule in TriggerEditSheet(rule: rule) }
    }

    private func triggerRow(_ rule: TriggerRule) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.trianglebadge.exclamationmark")
                .font(.system(size: AppStyle.fontMedium))
                .foregroundStyle(rule.isEnabled ? .orange : .secondary)
                .frame(width: AppStyle.buttonLarge, height: AppStyle.buttonLarge)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.name).font(.system(size: AppStyle.fontRegular, weight: .medium)).lineLimit(1)
                    Text(rule.actionType.displayName(i18n: i18n)).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color.secondary.opacity(0.15)).cornerRadius(4)
                }
                Text(rule.pattern).font(.system(size: AppStyle.fontSmall, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                if let payload = rule.actionPayload, !payload.isEmpty {
                    Text(payload).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: AppStyle.spacingM)
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { rule.isEnabled = $0; try? modelContext.save() }))
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingML)
        .contentShape(Rectangle())
        .onTapGesture { editingRule = rule }
        .contextMenu {
            Button { editingRule = rule } label: { Label(i18n.t(.edit), systemImage: "pencil") }
            Divider()
            Button(role: .destructive) { delete(rule) } label: { Label(i18n.t(.delete), systemImage: "trash") }
        }
    }

    private func delete(_ rule: TriggerRule) {
        modelContext.delete(rule)
        try? modelContext.save()
    }
}

// MARK: - Edit Sheet — mirrors AddHostSheet template

private struct TriggerEditSheet: View {
    @Environment(I18n.self) var i18n
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    var rule: TriggerRule?

    @State private var name = ""
    @State private var pattern = ""
    @State private var isRegex = true
    @State private var isCaseSensitive = false
    @State private var actionType: TriggerActionType = .highlight
    @State private var payload = ""
    @State private var isEnabled = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppStyle.spacingM) {
                Image(systemName: "bolt.trianglebadge.exclamationmark")
                    .font(.system(size: AppStyle.fontMedium, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: AppStyle.iconHero, height: AppStyle.iconHero)
                Text(rule == nil ? i18n.t(.addTrigger) : i18n.t(.editTrigger))
                    .font(.system(size: AppStyle.fontRegular, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, AppStyle.spacingXL)
            .padding(.vertical, AppStyle.spacingML)
            Divider()
            Form {
                Section(i18n.t(.triggerAction)) {
                    TextField(i18n.t(.triggerName), text: $name)
                    TextField(i18n.t(.triggerPattern), text: $pattern)
                        .autocorrectionDisabled()
                        .textContentType(.none)
                    Toggle(i18n.t(.triggerRegex), isOn: $isRegex)
                    Toggle(i18n.t(.triggerCaseSensitive), isOn: $isCaseSensitive)
                }

                Section(i18n.t(.triggerAction)) {
                    Picker(i18n.t(.triggerAction), selection: $actionType) {
                        ForEach(TriggerActionType.allCases, id: \.self) { action in Text(action.displayName(i18n: i18n)).tag(action) }
                    }.pickerStyle(.segmented)
                    switch actionType {
                    case .highlight:
                        Text(i18n.t(.triggerHighlightDesc)).font(.caption).foregroundStyle(.secondary)
                    case .notify:
                        TextField(i18n.t(.triggerNotify), text: $payload)
                    case .sendText:
                        TextField(i18n.t(.triggerSendText), text: $payload)
                            .autocorrectionDisabled()
                    }
                    Toggle(i18n.t(.triggerEnabled), isOn: $isEnabled)
                }
            }
            .formStyle(.grouped)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: AppStyle.panelWidthMedium)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(i18n.t(.cancel)) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(i18n.t(.save)) { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || pattern.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            if let triggerRule = rule {
                name = triggerRule.name; pattern = triggerRule.pattern; isRegex = triggerRule.isRegex; isCaseSensitive = triggerRule.isCaseSensitive
                actionType = triggerRule.actionType; payload = triggerRule.actionPayload ?? ""; isEnabled = triggerRule.isEnabled
            }
        }
    }

    private func save() {
        if let triggerRule = rule {
            triggerRule.name = name; triggerRule.pattern = pattern; triggerRule.isRegex = isRegex; triggerRule.isCaseSensitive = isCaseSensitive
            triggerRule.actionType = actionType; triggerRule.actionPayload = payload.isEmpty ? nil : payload; triggerRule.isEnabled = isEnabled
        } else {
            let new = TriggerRule(name: name, pattern: pattern, isRegex: isRegex, isCaseSensitive: isCaseSensitive, actionType: actionType, actionPayload: payload.isEmpty ? nil : payload, isEnabled: isEnabled)
            modelContext.insert(new)
        }
        try? modelContext.save()
        dismiss()
    }
}
