//
//  TriggerSettingsView.swift
//  Bonk
//
//  Manage regex triggers → highlight / notify / sendText.
//

import SwiftData
import SwiftUI

struct TriggerSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TriggerRule.createdAt, order: .reverse) private var rules: [TriggerRule]
    @State private var showAddSheet = false
    @State private var editingRule: TriggerRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Triggers", systemImage: "bolt.trianglebadge.exclamationmark")
                    .font(.headline)
                Spacer()
                Button { showAddSheet = true } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            Text("Match terminal output with regex and auto-highlight, notify, or send text. Throttled to once per second per rule.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if rules.isEmpty {
                ContentUnavailableView("No Triggers", systemImage: "bolt.slash", description: Text("Create a trigger to monitor output, e.g. pattern \"ERROR\" → Notify"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(rules) { rule in
                        triggerRow(rule)
                            .contentShape(Rectangle())
                            .onTapGesture { editingRule = rule }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { delete(rule) } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding()
        .sheet(isPresented: $showAddSheet) { TriggerEditSheet(rule: nil) }
        .sheet(item: $editingRule) { rule in TriggerEditSheet(rule: rule) }
    }

    private func triggerRow(_ rule: TriggerRule) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(rule.isEnabled ? Color.green : Color.gray).frame(width: 8, height: 8)
                    Text(rule.name).font(.body.weight(.medium)).lineLimit(1)
                    Text(rule.actionType.displayName).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color.secondary.opacity(0.15)).cornerRadius(4)
                }
                Text(rule.pattern).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                if let payload = rule.actionPayload, !payload.isEmpty {
                    Text(payload).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { rule.isEnabled = $0; try? modelContext.save() }))
                .labelsHidden()
        }.padding(.vertical, 4)
    }

    private func delete(_ rule: TriggerRule) {
        modelContext.delete(rule)
        try? modelContext.save()
    }
}

// MARK: - Edit Sheet

private struct TriggerEditSheet: View {
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
        NavigationStack {
            Form {
                Section("Trigger") {
                    TextField("Name", text: $name)
                    TextField("Pattern (regex or text)", text: $pattern)
                        .autocorrectionDisabled()
                    Toggle("Regex", isOn: $isRegex)
                    Toggle("Case Sensitive", isOn: $isCaseSensitive)
                }
                Section("Action") {
                    Picker("Action", selection: $actionType) {
                        ForEach(TriggerActionType.allCases, id: \.self) { t in Text(t.displayName).tag(t) }
                    }.pickerStyle(.segmented)
                    switch actionType {
                    case .highlight:
                        Text("Highlights matching output in log (currently logs only)").font(.caption).foregroundStyle(.secondary)
                    case .notify:
                        TextField("Notification title (optional)", text: $payload)
                    case .sendText:
                        TextField("Text to send + Enter", text: $payload)
                            .autocorrectionDisabled()
                    }
                    Toggle("Enabled", isOn: $isEnabled)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(rule == nil ? "Add Trigger" : "Edit Trigger")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || pattern.isEmpty)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 380)
        .onAppear {
            if let r = rule {
                name = r.name; pattern = r.pattern; isRegex = r.isRegex; isCaseSensitive = r.isCaseSensitive
                actionType = r.actionType; payload = r.actionPayload ?? ""; isEnabled = r.isEnabled
            }
        }
    }

    private func save() {
        if let r = rule {
            r.name = name; r.pattern = pattern; r.isRegex = isRegex; r.isCaseSensitive = isCaseSensitive
            r.actionType = actionType; r.actionPayload = payload.isEmpty ? nil : payload; r.isEnabled = isEnabled
        } else {
            let new = TriggerRule(name: name, pattern: pattern, isRegex: isRegex, isCaseSensitive: isCaseSensitive, actionType: actionType, actionPayload: payload.isEmpty ? nil : payload, isEnabled: isEnabled)
            modelContext.insert(new)
        }
        try? modelContext.save()
        dismiss()
    }
}
