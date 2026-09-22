import SwiftUI
import SwiftData
import AppKit

// MARK: - Add/Edit Sheet

enum PatternMode {
    case add
    case edit(LogPatternRow)
}

struct PatternEditSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var ctx
    var mode: PatternMode
    var profile: LogProfile?
    @State private var name = ""
    @State private var pattern = ""
    @State private var preset = "自定义"
    @State private var picked: Color = .red
    @State private var hex = "#FF3B30"
    @State private var priority = 50
    @State private var error: String?
    @State private var testLine = "2026-08-27 10:00:00 ERROR 192.168.1.1 hello world"

    var isEdit: Bool { if case .edit = mode { return true }; return false }
    private func sheetTitle() -> String { isEdit ? i18n.t(.logEditPattern) : i18n.t(.logAddPattern) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(sheetTitle()).font(.system(size: AppStyle.fontMedium, weight: .semibold))
                Spacer()
                Button(i18n.t(.cancel)) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isEdit ? i18n.t(.save) : i18n.t(.add)) { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(name.isEmpty || pattern.isEmpty)
            }.padding()
            Divider()
            Form {
                Section(i18n.t(.logBasic)) {
                    TextField(i18n.t(.logNamePlaceholder), text: $name).font(.system(size: AppStyle.fontBody))
                    Picker(i18n.t(.logPreset), selection: $preset) {
                        ForEach(LogColor.presetRows, id: \.title) { profile in Text(LogColor.displayTitle(profile.title)).tag(profile.title) }
                    }.onChange(of: preset) { _, value in
                        if let matchedPreset = LogColor.presetRows.first(where: { $0.title == value }) {
                            if !matchedPreset.pattern.isEmpty { pattern = matchedPreset.pattern }
                            if !matchedPreset.testLine.isEmpty { testLine = matchedPreset.testLine }
                            if !isEdit, !matchedPreset.ansi.isEmpty { picked = LogColor.color(for: matchedPreset.ansi); hex = (picked.hexString ?? "#FF3B30").uppercased() }
                        }
                    }
                    TextField(i18n.t(.logRegex), text: $pattern).font(.system(size: AppStyle.fontSmall, design: .monospaced))
                    if let displayError = error { Text(displayError).foregroundStyle(.red).font(.system(size: AppStyle.fontCaption)) }
                }
                Section(i18n.t(.logColorSection)) {
                    let defaults = LogColor.palette
                    let isCustom = !defaults.contains(where: { $0.uppercased() == hex.uppercased() })
                    HStack(spacing: AppStyle.spacingS) {
                        ForEach(defaults, id: \.self) { hexValue in
                            Circle().fill(Color(hex: hexValue)).frame(width: 28, height: 28)
                                .overlay(Circle().stroke(hex.uppercased() == hexValue.uppercased() ? Color.primary : Color.clear, lineWidth: 2))
                                .onTapGesture { hex = hexValue.uppercased(); picked = Color(hex: hexValue) }
                        }
                        ZStack {
                            Capsule().fill(picked).frame(width: 44, height: 24)
                                .overlay(Capsule().stroke(isCustom ? Color.primary : Color.clear, lineWidth: 2))
                                .allowsHitTesting(false)
                            ColorPicker("", selection: $picked).labelsHidden().opacity(0.02).frame(width: 44, height: 24)
                                .onChange(of: picked) { _, newColor in
                                    let newHex = (newColor.hexString ?? hex).uppercased()
                                    if isCustom || !defaults.contains(where: { $0.uppercased() == newHex.uppercased() }) { hex = newHex }
                                }
                        }.help(i18n.t(.logCustomColor))
                        TextField("", text: $hex).font(.system(size: AppStyle.fontSmall, design: .monospaced)).frame(width: 86, alignment: .leading).lineLimit(1).textFieldStyle(.plain)
                            .onChange(of: hex) { _, newHex in if newHex.hasPrefix("#") && newHex.count == 7 { picked = Color(hex: newHex) } }
                    }
                }
                Section(i18n.t(.logLivePreview)) {
                    if pattern.isEmpty {
                        Text(i18n.t(.logEnterPattern)).font(.system(size: AppStyle.fontCaption)).foregroundStyle(.secondary)
                    } else if (try? NSRegularExpression(pattern: pattern)) == nil {
                        Label(i18n.t(.logInvalidRegex), systemImage: "xmark.octagon.fill").font(.system(size: AppStyle.fontCaption)).foregroundStyle(.red)
                    } else {
                        let matchResult = (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?.matches(in: testLine, range: NSRange(testLine.startIndex..., in: testLine))
                        SingleLineHighlightField(text: $testLine, pattern: pattern, color: picked).frame(height: 22)
                        HStack {
                            Label((matchResult?.isEmpty ?? true) ? i18n.t(.logNoMatch) : i18n.tr(.logMatchCount, args: matchResult!.count), systemImage: (matchResult?.isEmpty ?? true) ? "exclamationmark.triangle" : "checkmark.circle.fill")
                                .font(.system(size: AppStyle.fontSmall, weight: .medium)).foregroundStyle((matchResult?.isEmpty ?? true) ? .orange : .green)
                            Spacer()
                            Text(i18n.tr(.logPriority, args: priority)).font(.system(size: AppStyle.fontCaption)).foregroundStyle(.secondary)
                            Stepper("", value: $priority, in: 1...100).labelsHidden().controlSize(.small)
                        }
                    }
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
        }
        .frame(width: 560, height: 520)
        .onAppear { load() }
    }

    func load() {
        if case .edit(let row) = mode {
            name = row.name; pattern = row.pattern; priority = row.priority
            hex = LogColor.hex(for: row.ansiCode).uppercased()
            picked = Color(hex: hex)
            if let matchedPreset = LogColor.presetRows.first(where: { $0.pattern == row.pattern }) {
                preset = matchedPreset.title
                testLine = matchedPreset.testLine
            } else {
                // No preset match: keep current pattern but ensure preview has some content
                if testLine.trimmingCharacters(in: .whitespaces).isEmpty { testLine = row.pattern }
            }
        } else if let matchedPreset = LogColor.presetRows.first(where: { $0.title == preset }) {
            picked = LogColor.color(for: matchedPreset.ansi)
            hex = (picked.hexString ?? "#FF3B30").uppercased()
        }
    }

    func save() {
        let ansi = LogColor.ansi(for: hex)
        if case .edit(let row) = mode {
            row.name = name; row.pattern = pattern; row.ansiCode = ansi; row.priority = priority
            try? ctx.save()
            Task { @MainActor in LogProfileStore.shared.refreshSnapshot() }
            dismiss()
        } else {
            if LogProfileStore.shared.addRow(to: profile!, name: name, pattern: pattern, ansiCode: ansi, priority: priority) { dismiss() } else { error = i18n.t(.logSaveError) }
        }
    }
}
