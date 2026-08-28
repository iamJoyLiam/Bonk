import SwiftUI
import SwiftData
import AppKit

// MARK: - Main

struct LogPatternSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LogProfile.createdAt) private var profiles: [LogProfile]
    @State private var selectedID: UUID?
    @State private var showAdd = false
    @State private var editingRow: LogPatternRow?
    @State private var showEdit = false
    @State private var showDeleteProfile = false
    @State private var showDeleteRow = false
    @State private var rowToDelete: LogPatternRow? = nil
    @State private var editingName = false
    @State private var draftName = ""

    var selected: LogProfile? {
        profiles.first { $0.id == selectedID } ?? profiles.first { $0.isDefault } ?? profiles.first
    }

    var body: some View {
        HSplitView {
            // Left: Profiles — clean, no header, no count, no gray bg
            List(profiles, id: \.id, selection: $selectedID) { p in
                HStack(spacing: AppStyle.spacingS) {
                    Circle().fill(p.isDefault ? Color.green : Color.blue).frame(width: 8, height: 8)
                    Text(p.name).font(.system(size: AppStyle.fontBody)).lineLimit(1)
                    Spacer()
                    if p.isDefault {
                        Text("默认").font(.system(size: AppStyle.fontCaption)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12)).cornerRadius(4)
                    }
                }.tag(p.id).padding(.vertical, 2)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(minWidth: 180, maxWidth: 220)

            // Right: Detail
            if let profile = selected {
                VStack(spacing: 0) {
                    HStack(spacing: AppStyle.spacingM) {
                        VStack(alignment: .leading, spacing: 2) {
                            if editingName {
                                TextField("名称", text: $draftName, onCommit: {
                                    profile.name = draftName; try? modelContext.save(); editingName = false
                                }).font(.system(size: AppStyle.fontMedium, weight: .semibold)).frame(width: 180)
                                    .onExitCommand { editingName = false }
                            } else {
                                HStack(spacing: 6) {
                                    Text(profile.name).font(.system(size: AppStyle.fontMedium, weight: .semibold))
                                    Button { draftName = profile.name; editingName = true } label: { Image(systemName: "pencil").font(.system(size: 11)) }.buttonStyle(.plain).help("重命名")
                                }
                            }
                            Text("\(profile.patterns.count) 条规则 · \(profile.patterns.filter{ $0.enabled }.count) 启用")
                                .font(.system(size: AppStyle.fontCaption)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("新建配置") {
                            if let p = LogProfileStore.shared.create(name: "配置 \(profiles.count+1)") { selectedID = p.id }
                        }.controlSize(.small)
                        if !profile.isDefault {
                            Button("删除", role: .destructive) { showDeleteProfile = true }
                                .controlSize(.small).buttonStyle(.bordered)
                        }
                    }.padding(AppStyle.spacingM)
                    .confirmationDialog("删除配置 \(profile.name)？", isPresented: $showDeleteProfile, titleVisibility: .visible) {
                        Button("删除", role: .destructive) {
                            modelContext.delete(profile)
                            try? modelContext.save()
                            // reset selection
                            selectedID = profiles.first { $0.id != profile.id }?.id
                        }
                        Button("取消", role: .cancel) {}
                    } message: { Text("配置内 \(profile.patterns.count) 条规则将一并删除，不可恢复") }

                    Divider()

                    VStack(alignment: .leading, spacing: AppStyle.spacingS) {
                        HStack {
                            Label("实时预览", systemImage: "eye").font(.system(size: AppStyle.fontSmall, weight: .medium)).foregroundStyle(.secondary)
                            Spacer()
                        }
                        LogPreviewView(profile: profile)
                            .padding(AppStyle.spacingS)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(AppStyle.cornerRadiusSmall)
                            .overlay(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    }.padding(AppStyle.spacingM)

                    Divider()

                    HStack {
                        Text("规则").font(.system(size: AppStyle.fontSmall, weight: .semibold))
                        Spacer()
                        Button { showAdd = true } label: { Label("添加正则", systemImage: "plus") }.controlSize(.small).buttonStyle(.borderedProminent)
                    }.padding(.horizontal, AppStyle.spacingM).padding(.vertical, AppStyle.spacingS)

                    List {
                        ForEach(profile.patterns) { row in
                            PatternRowView(row: row, onEdit: { editingRow = row; showEdit = true }, onDelete: {
                                rowToDelete = row; showDeleteRow = true
                            })
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        }
                    }.listStyle(.plain)
                    .confirmationDialog("删除正则", isPresented: $showDeleteRow, titleVisibility: .visible) {
                        if let r = rowToDelete {
                            Button("删除 \(r.name)", role: .destructive) {
                                modelContext.delete(r); try? modelContext.save()
                            }
                            Button("取消", role: .cancel) {}
                        }
                    } message: { Text("正则删除后不可恢复") }
                }
            } else {
                ContentUnavailableView("无配置", systemImage: "paintbrush", description: Text("新建一个日志着色配置"))
            }
        }
        .sheet(isPresented: $showAdd) {
            PatternEditSheet(mode: .add, profile: selected)
        }
        .sheet(item: $editingRow) { row in
            PatternEditSheet(mode: .edit(row), profile: selected)
        }
        .onAppear {
            if selectedID == nil { selectedID = profiles.first { $0.isDefault }?.id ?? profiles.first?.id }
            LogProfileStore.shared.configure(container: modelContext.container)
        }
    }
}

// MARK: - Row

struct PatternRowView: View {
    @Bindable var row: LogPatternRow
    var onEdit: () -> Void
    var onDelete: () -> Void
    @Environment(\.modelContext) private var ctx

    var body: some View {
        HStack(spacing: AppStyle.spacingM) {
            Circle().fill(color(for: row.ansiCode)).frame(width: 12, height: 12).shadow(radius: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: AppStyle.fontBody, weight: .medium)).lineLimit(1)
                Text(row.pattern).font(.system(size: AppStyle.fontCaption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { row.enabled }, set: { new in row.enabled = new; try? ctx.save(); Task { await LogProfileStore.shared.load() } })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            Button(action: onEdit) { Image(systemName: "pencil") }.buttonStyle(.plain).help("编辑")
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.plain).help("删除")
        }.padding(.vertical, 4)
    }
    func color(for code: String) -> Color {
        if code.hasPrefix("38;2;") {
            let p = code.split(separator: ";").compactMap{ Int($0) }
            if p.count>=5 { return Color(red: Double(p[2])/255, green: Double(p[3])/255, blue: Double(p[4])/255) }
        }
        if code.hasPrefix("#") { return Color(hex: code) }
        switch code {
        case "1;31": return .red
        case "1;33": return .yellow
        case "1;34": return .blue
        case "1;35": return .purple
        case "2;32": return .green
        default: return .gray
        }
    }
}

// MARK: - Preview

struct LogPreviewView: View {
    let profile: LogProfile
    @State private var multi = "2026-08-27 10:00:00 INFO hello 192.168.1.1\n2026-08-27 10:00:00 ERROR failed 10.0.0.1\n{\"level\":\"error\",\"msg\":\"boom\"}\nlevel=warn msg=\"slow\"\nmy-alert-service Up 5 minutes\n2026/08/27 10:00:00 [error] 192.168.1.1"
    var body: some View {
        ProfileHighlightField(text: $multi, profile: profile)
            .frame(minHeight: 72, idealHeight: 84, maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
    }
    func highlighted(_ line: String) -> AttributedString {
        var attr = AttributedString(line)
        attr.foregroundColor = .primary
        var spans: [(NSRange, Color)] = []
        for row in profile.patterns.filter({ $0.enabled }) {
            guard let re = try? NSRegularExpression(pattern: row.pattern, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: line, range: NSRange(line.startIndex..., in: line)) { spans.append((m.range, color(for: row.ansiCode))) }
        }
        spans.sort { $0.0.location < $1.0.location }
        var lastEnd = -1
        for (r, c) in spans {
            if r.location < lastEnd { continue }
            if let s = Range(r, in: line), let a = Range(s, in: attr) { attr[a].foregroundColor = c; attr[a].font = .system(size: AppStyle.fontSmall, design: .monospaced).bold() }
            lastEnd = NSMaxRange(r)
        }
        return attr
    }
    func color(for code: String) -> Color {
        if code.hasPrefix("38;2;") { let p = code.split(separator: ";").compactMap{ Int($0) }; if p.count>=5 { return Color(red: Double(p[2])/255, green: Double(p[3])/255, blue: Double(p[4])/255) } }
        if code.hasPrefix("#") { return Color(hex: code) }
        switch code { case "1;31": return .red; case "1;33": return .yellow; case "1;34": return .blue; case "1;35": return .purple; case "2;32": return .green; default: return .gray }
    }
}

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
    @State private var preset = "custom"
    @State private var picked: Color = .red
    @State private var hex = "#FF3B30"
    @State private var priority = 50
    @State private var error: String?
    @State private var testLine = "2026-08-27 10:00:00 ERROR 192.168.1.1 hello world"

    let presets: [(String,String,String)] = [
        ("Emerg","(?<![A-Za-z0-9_\\-])(?:EMERG(?:ENCY)?|PANIC)(?![A-Za-z0-9_\\-])","1;41;97"),
        ("Alert","(?<![A-Za-z0-9_\\-])ALERT(?![A-Za-z0-9_\\-])","1;41;97"),
        ("Crit","(?<![A-Za-z0-9_\\-])(?:CRIT(?:ICAL)?)(?![A-Za-z0-9_\\-])","1;91"),
        ("Fatal","(?<![A-Za-z0-9_\\-])FATAL(?![A-Za-z0-9_\\-])","1;91"),
        ("Error","(?<![A-Za-z0-9_\\-])(?:ERR(?:OR)?)(?![A-Za-z0-9_\\-])","1;31"),
        ("Fail","(?<![A-Za-z0-9_\\-])(?:FAIL(?:ED)?|FAILURE)(?![A-Za-z0-9_\\-])","1;31"),
        ("Warn","(?<![A-Za-z0-9_\\-])(?:WARN(?:ING)?)(?![A-Za-z0-9_\\-])","1;33"),
        ("Notice","(?<![A-Za-z0-9_\\-])NOTICE(?![A-Za-z0-9_\\-])","1;32"),
        ("Info","(?<![A-Za-z0-9_\\-])(?:INFO(?:RMATIONAL)?)(?![A-Za-z0-9_\\-])","1;34"),
        ("Debug","(?<![A-Za-z0-9_\\-])(?:DEBUG|TRACE)(?![A-Za-z0-9_\\-])","2"),
        ("IP","\\b(?:(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)\\.){3}(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)\\b","1;34"),
        ("时间戳","\\d{4}[-/]\\d{2}[-/]\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}","2;32"),
        ("JSON level","\"(?:level|severity)\"\\s*:\\s*\"[^\"]+\"","1;35"),
        ("Logfmt","\\blevel=(?:error|warn|info|debug)\\b","1;35"),
        ("自定义","", ""),
    ]

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
                        ForEach(presets, id: \.0) { p in Text(p.0).tag(p.0) }
                    }.onChange(of: preset) { _, v in
                        if let p = presets.first(where: { $0.0==v }) {
                            if !p.1.isEmpty { pattern = p.1 }
                            switch p.0 {
                            case "Emerg": testLine = "2026-08-27 10:00:00 EMERG panic 192.168.1.1"
                            case "Alert": testLine = "2026-08-27 10:00:00 ALERT 192.168.1.1"
                            case "Crit": testLine = "2026-08-27 10:00:00 CRIT 192.168.1.1 hello"
                            case "Fatal": testLine = "2026-08-27 10:00:00 FATAL 192.168.1.1"
                            case "Error": testLine = "2026-08-27 10:00:00 ERROR 192.168.1.1 hello"
                            case "Fail": testLine = "2026-08-27 10:00:00 FAIL 192.168.1.1"
                            case "Warn": testLine = "2026-08-27 10:00:00 WARN hello 192.168.1.1"
                            case "Notice": testLine = "2026-08-27 10:00:00 NOTICE hello"
                            case "Info": testLine = "2026-08-27 10:00:00 INFO hello 192.168.1.1"
                            case "Debug": testLine = "2026-08-27 10:00:00 DEBUG trace"
                            case "IP": testLine = "2026-08-27 10:00:00 INFO 192.168.1.1"
                            case "时间戳": testLine = "2026-08-27 10:00:00 hello"
                            case "JSON level": testLine = "{\"level\":\"error\",\"msg\":\"boom\"}"
                            case "Logfmt": testLine = "level=error msg=boom"
                            default: break
                            }
                            if !isEdit, !p.2.isEmpty { picked = colorForCode(p.2); hex = picked.hexString ?? "#FF3B30" }
                        }
                    }
                    TextField("正则表达式", text: $pattern).font(.system(size: AppStyle.fontSmall, design: .monospaced))
                    if let e = error { Text(e).foregroundStyle(.red).font(.system(size: AppStyle.fontCaption)) }
                }
                Section("颜色") {
                    let defaults = ["#FF3B30","#FF9500","#FFCC02","#34C759","#007AFF","#AF52DE"]
                    let isCustom = !defaults.contains(where: { $0.uppercased() == hex.uppercased() })
                    HStack(spacing: AppStyle.spacingS) {
                        ForEach(defaults, id: \.self) { h in
                            Circle().fill(Color(hex: h)).frame(width: 28, height: 28)
                                .overlay(Circle().stroke(hex.uppercased() == h.uppercased() ? Color.primary : Color.clear, lineWidth: 2))
                                .onTapGesture { hex=h.uppercased(); picked=Color(hex: h) }
                        }
                        ZStack {
                            Capsule().fill(picked).frame(width: 44, height: 24)
                                .overlay(Capsule().stroke(isCustom ? Color.primary : Color.clear, lineWidth: 2))
                                .allowsHitTesting(false)
                            ColorPicker("", selection: $picked).labelsHidden().opacity(0.02).frame(width: 44, height: 24)
                                .onChange(of: picked) { _, c in
                                    let nh = c.hexString ?? hex
                                    // 仅自定义时跟随，避免默认色因 rounding 跳到自定义
                                    if isCustom || !defaults.contains(where: { $0.uppercased() == nh.uppercased() }) { hex = nh.uppercased() }
                                }
                        }.help("自定义取色")
                        TextField("", text: $hex).font(.system(size: AppStyle.fontSmall, design: .monospaced)).frame(width: 86, alignment: .leading).lineLimit(1).textFieldStyle(.plain)
                            .onChange(of: hex) { _, h in if h.hasPrefix("#") && h.count==7 { picked = Color(hex: h) } }
                    }
                }
                Section("实时预览") {
                    if pattern.isEmpty {
                        Text("请输入正则").font(.system(size: AppStyle.fontCaption)).foregroundStyle(.secondary)
                    } else if (try? NSRegularExpression(pattern: pattern)) == nil {
                        Label("正则非法", systemImage: "xmark.octagon.fill").font(.system(size: AppStyle.fontCaption)).foregroundStyle(.red)
                    } else {
                        let m = (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?.matches(in: testLine, range: NSRange(testLine.startIndex..., in: testLine))
                        SingleLineHighlightField(text: $testLine, pattern: pattern, color: picked)
                            .frame(height: 22)
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
            name=row.name; pattern=row.pattern; priority=row.priority
            if row.ansiCode.hasPrefix("38;2;") { hex=hexForAnsi(row.ansiCode); picked=Color(hex: hex) }
            else if row.ansiCode.hasPrefix("#") { hex=row.ansiCode; picked=Color(hex: hex) }
            else { picked=colorForCode(row.ansiCode); hex=picked.hexString ?? "#FF3B30" }
            if let p = presets.first(where: { $0.2==row.ansiCode }) { preset=p.0 }
        } else if let p = presets.first(where: { $0.0==preset }) { picked=colorForCode(p.2); hex=picked.hexString ?? "#FF3B30" }
    }
    func save() {
        if case .edit(let row) = mode {
            row.name=name; row.pattern=pattern; row.ansiCode=ansiForHex(hex); row.priority=priority
            try? ctx.save()
            LogProfileStore.shared.configure(container: ctx.container)
            dismiss()
        } else {
            let code = ansiForHex(hex)
            if LogProfileStore.shared.addRow(to: profile!, name: name, pattern: pattern, ansiCode: code, priority: priority) { dismiss() } else { error="正则非法或保存失败" }
        }
    }
    func ansiForHex(_ hex: String) -> String { let c=Color(hex: hex); let ns=NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c); return "38;2;\(Int(ns.redComponent*255));\(Int(ns.greenComponent*255));\(Int(ns.blueComponent*255))" }
    func hexForAnsi(_ code: String) -> String {
        if code.hasPrefix("#") { return code }
        let p=code.split(separator: ";").compactMap{ Int($0) }
        if p.count>=5 { return String(format: "#%02X%02X%02X", p[2], p[3], p[4]) }
        return "#FF3B30"
    }
    func colorForCode(_ code: String) -> Color {
        if code.hasPrefix("38;2;") { let p=code.split(separator: ";").compactMap{ Int($0) }; if p.count>=5 { return Color(red: Double(p[2])/255, green: Double(p[3])/255, blue: Double(p[4])/255) } }
        if code.hasPrefix("#") { return Color(hex: code) }
        switch code { case "1;31": return .red; case "1;33": return .yellow; case "1;34": return .blue; case "1;35": return .purple; case "2;32": return .green; default: return .gray }
    }
    func previewAttr(_ line: String, pattern: String, color: Color) -> AttributedString {
        var a=AttributedString(line)
        guard let re=try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return a }
        for m in re.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            if let r = Range(m.range, in: line), let ar = Range(r, in: a) { a[ar].foregroundColor = color; a[ar].font = .system(size: AppStyle.fontSmall, design: .monospaced).bold() }
        }
        return a
    }
}

// MARK: - Single line editable highlight (one line, keep highlight while editing)
private final class HighlightTextView: NSTextView {
    var onChange: ((String) -> Void)?
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }
    override func becomeFirstResponder() -> Bool { let r=super.becomeFirstResponder(); needsDisplay=true; return r }
    override func resignFirstResponder() -> Bool { let r=super.resignFirstResponder(); needsDisplay=true; return r }
}
struct SingleLineHighlightField: NSViewRepresentable {
    @Binding var text: String
    var pattern: String
    var color: Color
    func makeNSView(context: Context) -> NSScrollView {
        let tv = HighlightTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 22))
        tv.isEditable = true; tv.isSelectable = true; tv.drawsBackground = false
        tv.backgroundColor = .clear; tv.focusRingType = .none
        tv.isRichText = true; tv.allowsUndo = true; tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainer?.lineFragmentPadding = 2; tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.isHorizontallyResizable = false; tv.isVerticallyResizable = false
        tv.textContainer?.widthTracksTextView = true; tv.textContainer?.lineBreakMode = .byTruncatingTail
        tv.delegate = context.coordinator; tv.onChange = { text = $0 }
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 22))
        sv.hasVerticalScroller = false; sv.hasHorizontalScroller = false; sv.drawsBackground = false
        sv.backgroundColor = .clear; sv.borderType = .noBorder; sv.documentView = tv
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? HighlightTextView else { return }
        let sel = tv.selectedRange()
        let isFirst = tv.window?.firstResponder == tv
        let attr = NSMutableAttributedString(string: text)
        attr.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), range: NSRange(location: 0, length: attr.length))
        attr.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: attr.length))
        if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                attr.addAttribute(.foregroundColor, value: NSColor(color), range: m.range)
                attr.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), range: m.range)
            }
        }
        if tv.string != text || !(tv.textStorage?.isEqual(to: attr) ?? false) {
            tv.textStorage?.setAttributedString(attr)
            if sel.location != NSNotFound && sel.location <= attr.length { tv.setSelectedRange(sel) }
            if isFirst { tv.setSelectedRange(sel) }
        }
        tv.onChange = { text = $0 }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SingleLineHighlightField
        init(_ p: SingleLineHighlightField) { parent = p }
        func textDidChange(_ n: Notification) { guard let tv=n.object as? NSTextView else { return }; parent.text = tv.string }
    }
}
struct ProfileHighlightField: NSViewRepresentable {
    @Binding var text: String
    var profile: LogProfile
    func makeNSView(context: Context) -> NSScrollView {
        let tv = HighlightTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 84))
        tv.isEditable = true; tv.isSelectable = true; tv.drawsBackground = false
        tv.backgroundColor = .clear; tv.isRichText = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainer?.lineFragmentPadding = 2; tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.isHorizontallyResizable = false; tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true; tv.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.lineBreakMode = .byWordWrapping; tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.delegate = context.coordinator; tv.onChange = { text = $0 }
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 84))
        sv.hasVerticalScroller = false; sv.hasHorizontalScroller = false; sv.drawsBackground = false
        sv.backgroundColor = .clear; sv.borderType = .noBorder; sv.documentView = tv
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? HighlightTextView else { return }
        let sel = tv.selectedRange()
        let isFirst = tv.window?.firstResponder == tv
        let attr = NSMutableAttributedString(string: text)
        attr.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), range: NSRange(location: 0, length: attr.length))
        attr.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: attr.length))
        for row in profile.patterns.filter({ $0.enabled }) {
            guard let re = try? NSRegularExpression(pattern: row.pattern, options: [.caseInsensitive]) else { continue }
            let col: NSColor
            if row.ansiCode.hasPrefix("38;2;") { let p=row.ansiCode.split(separator: ";").compactMap{ Int($0) }; col = p.count>=5 ? NSColor(srgbRed: CGFloat(p[2])/255, green: CGFloat(p[3])/255, blue: CGFloat(p[4])/255, alpha: 1) : NSColor.gray }
            else if row.ansiCode.hasPrefix("#") { col = NSColor(Color(hex: row.ansiCode)) }
            else { col = row.ansiCode=="1;31" ? .systemRed : row.ansiCode=="1;33" ? .systemYellow : row.ansiCode=="1;34" ? .systemBlue : row.ansiCode=="1;35" ? .systemPurple : row.ansiCode=="2;32" ? .systemGreen : .gray }
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                attr.addAttribute(.foregroundColor, value: col, range: m.range)
                attr.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), range: m.range)
            }
        }
        if tv.string != text || !(tv.textStorage?.isEqual(to: attr) ?? false) {
            tv.textStorage?.setAttributedString(attr)
            if sel.location != NSNotFound && sel.location <= attr.length { tv.setSelectedRange(sel) }
            if isFirst { tv.setSelectedRange(sel) }
        }
        tv.onChange = { text = $0 }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ProfileHighlightField
        init(_ p: ProfileHighlightField) { parent = p }
        func textDidChange(_ n: Notification) { guard let tv=n.object as? NSTextView else { return }; parent.text = tv.string }
    }
}
