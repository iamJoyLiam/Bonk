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
    var title: String { isEdit ? "编辑正则" : "添加正则" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: AppStyle.fontMedium, weight: .semibold))
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isEdit ? "保存" : "添加") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(name.isEmpty || pattern.isEmpty)
            }.padding()
            Divider()
            Form {
                Section("基础") {
                    TextField("名称", text: $name).font(.system(size: AppStyle.fontBody))
                    Picker("预设", selection: $preset) {
                        ForEach(LogColor.presetRows, id: \.title) { p in Text(p.title).tag(p.title) }
                    }.onChange(of: preset) { _, v in
                        if let p = LogColor.presetRows.first(where: { $0.title == v }) {
                            if !p.pattern.isEmpty { pattern = p.pattern }
                            if !p.testLine.isEmpty { testLine = p.testLine }
                            if !isEdit, !p.ansi.isEmpty { picked = LogColor.color(for: p.ansi); hex = (picked.hexString ?? "#FF3B30").uppercased() }
                        }
                    }
                    TextField("正则表达式", text: $pattern).font(.system(size: AppStyle.fontSmall, design: .monospaced))
                    if let e = error { Text(e).foregroundStyle(.red).font(.system(size: AppStyle.fontCaption)) }
                }
                Section("颜色") {
                    let defaults = LogColor.palette
                    let isCustom = !defaults.contains(where: { $0.uppercased() == hex.uppercased() })
                    HStack(spacing: AppStyle.spacingS) {
                        ForEach(defaults, id: \.self) { h in
                            Circle().fill(Color(hex: h)).frame(width: 28, height: 28)
                                .overlay(Circle().stroke(hex.uppercased() == h.uppercased() ? Color.primary : Color.clear, lineWidth: 2))
                                .onTapGesture { hex = h.uppercased(); picked = Color(hex: h) }
                        }
                        ZStack {
                            Capsule().fill(picked).frame(width: 44, height: 24)
                                .overlay(Capsule().stroke(isCustom ? Color.primary : Color.clear, lineWidth: 2))
                                .allowsHitTesting(false)
                            ColorPicker("", selection: $picked).labelsHidden().opacity(0.02).frame(width: 44, height: 24)
                                .onChange(of: picked) { _, c in
                                    let nh = (c.hexString ?? hex).uppercased()
                                    if isCustom || !defaults.contains(where: { $0.uppercased() == nh.uppercased() }) { hex = nh }
                                }
                        }.help("自定义取色")
                        TextField("", text: $hex).font(.system(size: AppStyle.fontSmall, design: .monospaced)).frame(width: 86, alignment: .leading).lineLimit(1).textFieldStyle(.plain)
                            .onChange(of: hex) { _, h in if h.hasPrefix("#") && h.count == 7 { picked = Color(hex: h) } }
                    }
                }
                Section("实时预览") {
                    if pattern.isEmpty {
                        Text("请输入正则").font(.system(size: AppStyle.fontCaption)).foregroundStyle(.secondary)
                    } else if (try? NSRegularExpression(pattern: pattern)) == nil {
                        Label("正则非法", systemImage: "xmark.octagon.fill").font(.system(size: AppStyle.fontCaption)).foregroundStyle(.red)
                    } else {
                        let m = (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?.matches(in: testLine, range: NSRange(testLine.startIndex..., in: testLine))
                        SingleLineHighlightField(text: $testLine, pattern: pattern, color: picked).frame(height: 22)
                        HStack {
                            Label((m?.isEmpty ?? true) ? "无匹配" : "\(m!.count) 处匹配", systemImage: (m?.isEmpty ?? true) ? "exclamationmark.triangle" : "checkmark.circle.fill")
                                .font(.system(size: AppStyle.fontSmall, weight: .medium)).foregroundStyle((m?.isEmpty ?? true) ? .orange : .green)
                            Spacer()
                            Text("优先级 \(priority)").font(.system(size: AppStyle.fontCaption)).foregroundStyle(.secondary)
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
            if let p = LogColor.presetRows.first(where: { $0.pattern == row.pattern }) {
                preset = p.title
                testLine = p.testLine
            } else {
                // No preset match: keep current pattern but ensure preview has some content
                if testLine.trimmingCharacters(in: .whitespaces).isEmpty { testLine = row.pattern }
            }
        } else if let p = LogColor.presetRows.first(where: { $0.title == preset }) {
            picked = LogColor.color(for: p.ansi)
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
            if LogProfileStore.shared.addRow(to: profile!, name: name, pattern: pattern, ansiCode: ansi, priority: priority) { dismiss() } else { error = "正则非法或保存失败" }
        }
    }
}
