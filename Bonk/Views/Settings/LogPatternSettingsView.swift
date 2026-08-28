import SwiftUI
import SwiftData
import AppKit

struct LogPatternSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LogProfile.createdAt) private var profiles: [LogProfile]
    @State private var selectedID: UUID?
    @State private var newPatternName = ""
    @State private var newPattern = ""
    @State private var newColor = "1;31"
    @State private var showAdd = false

    var selected: LogProfile? { profiles.first { $0.id == selectedID } ?? profiles.first { $0.isDefault } ?? profiles.first }

    var body: some View {
        HSplitView {
            List(profiles, id: \.id, selection: $selectedID) { p in
                HStack {
                    Text(p.name)
                    if p.isDefault { Text("默认").font(.caption).foregroundStyle(.secondary) }
                }.tag(p.id)
            }.frame(minWidth: 160)

            if let profile = selected {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(profile.name).font(.headline)
                        Spacer()
                        Button("新建配置") { LogProfileStore.shared.create(name: "MyProfile \(profiles.count+1)") }
                        if !profile.isDefault {
                            Button("删除", role: .destructive) { LogProfileStore.shared.delete(profile) }
                        }
                    }
                    Divider()
                    Text("预览").font(.subheadline).foregroundStyle(.secondary)
                    LogPreviewView(profile: profile)
                        .frame(height: 120)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)

                    HStack {
                        Text("正则").font(.caption)
                        Spacer()
                        Button("添加") { showAdd = true }
                    }
                    List {
                        ForEach(profile.patterns) { row in
                            HStack {
                                Circle().fill(color(for: row.ansiCode)).frame(width: 10, height: 10)
                                Text(row.name).font(.caption).frame(width: 70, alignment: .leading)
                                Text(row.pattern).font(.system(.caption, design: .monospaced)).lineLimit(1)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { row.enabled },
                                    set: { row.enabled = $0; try? modelContext.save() }
                                )).labelsHidden()
                            }
                        }
                        .onDelete { idx in
                            for i in idx { modelContext.delete(profile.patterns[i]) }
                            try? modelContext.save()
                        }
                    }
                }.padding()
            } else {
                ContentUnavailableView("无配置", systemImage: "paintbrush")
            }
        }
        .sheet(isPresented: $showAdd) {
            AddPatternSheet { name, pat, code in
                guard let p = selected else { return false }
                return LogProfileStore.shared.addRow(to: p, name: name, pattern: pat, ansiCode: code, priority: 50)
            }
        }
        .onAppear {
            if selectedID == nil { selectedID = profiles.first { $0.isDefault }?.id ?? profiles.first?.id }
            LogProfileStore.shared.configure(container: modelContext.container)
        }
    }

    func color(for code: String) -> Color {
        if code.hasPrefix("38;2;") {
            let parts = code.split(separator: ";").compactMap { Int($0) }
            if parts.count >= 5 { return Color(red: Double(parts[2])/255, green: Double(parts[3])/255, blue: Double(parts[4])/255) }
        }
        if code.hasPrefix("#") { return Color(hex: code) }
        switch code {
        case "1;31": return .red
        case "1;33": return .yellow
        case "1;34": return .blue
        case "1;35": return .purple
        case "2;32": return .green
        case "2": return .gray
        default: return .gray
        }
    }
}

struct LogPreviewView: View {
    let profile: LogProfile
    let samples = [
        "2026-08-27 10:00:00 INFO hello 192.168.1.1",
        "2026-08-27 10:00:00 ERROR failed 10.0.0.1",
        "{\"level\":\"error\",\"msg\":\"boom\"}",
        "level=warn msg=\"slow\"",
        "my-alert-service Up 5 minutes",
        "2026/08/27 10:00:00 [error] 192.168.1.1",
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(samples, id: \.self) { s in
                Text(highlighted(s))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
    func highlighted(_ line: String) -> AttributedString {
        var attr = AttributedString(line)
        attr.foregroundColor = .primary
        let patterns = profile.patterns.filter { $0.enabled }
        var spans: [(range: NSRange, color: Color)] = []
        for row in patterns {
            guard let re = try? NSRegularExpression(pattern: row.pattern, options: [.caseInsensitive]) else { continue }
            let r = NSRange(line.startIndex..., in: line)
            for m in re.matches(in: line, range: r) { spans.append((m.range, color(for: row.ansiCode))) }
        }
        spans.sort { $0.range.location < $1.range.location }
        var lastEnd = -1
        for (range, col) in spans {
            if range.location < lastEnd { continue }
            if let swiftRange = Range(range, in: line), let attrRange = Range(swiftRange, in: attr) {
                attr[attrRange].foregroundColor = col
                attr[attrRange].font = .system(.caption, design: .monospaced).bold()
            }
            lastEnd = NSMaxRange(range)
        }
        return attr
    }
    func color(for code: String) -> Color {
        if code.hasPrefix("38;2;") {
            let parts = code.split(separator: ";").compactMap { Int($0) }
            if parts.count >= 5 { return Color(red: Double(parts[2])/255, green: Double(parts[3])/255, blue: Double(parts[4])/255) }
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

struct AddPatternSheet: View {
    @Environment(\.dismiss) var dismiss
    @State var name = ""
    @State var pattern = ""
    @State var color = "1;31"
    @State var customHex = "#FF3B30"
    @State var useCustom = false
    @State var picked: Color = .red
    var onAdd: (String,String,String) -> Bool
    @State var error: String?
    @State var testLine = "2026-08-27 10:00:00 ERROR 192.168.1.1 hello"
    var resolvedCode: String {
        if useCustom {
            if customHex.hasPrefix("#") { return ansiForHex(customHex) }
            return customHex
        }
        return color
    }
    var body: some View {
        Form {
            TextField("名称", text: $name)
            TextField("正则", text: $pattern).font(.system(.caption, design: .monospaced))
                .onChange(of: pattern) { _, _ in validate() }
            Section("颜色") {
                Picker("预设", selection: $color) {
                    Text("红 1;31").tag("1;31")
                    Text("黄 1;33").tag("1;33")
                    Text("蓝 1;34").tag("1;34")
                    Text("紫 1;35").tag("1;35")
                    Text("绿 2;32").tag("2;32")
                    Text("灰 2").tag("2")
                }.disabled(useCustom)
                Toggle("自定义", isOn: $useCustom)
                if useCustom {
                    HStack {
                        ColorPicker("着色板", selection: $picked).onChange(of: picked) { _, c in customHex = c.hexString ?? "#FF3B30" }
                        TextField("#HEX", text: $customHex).font(.system(.caption, design: .monospaced))
                            .onChange(of: customHex) { _, h in picked = Color(hex: h) }
                        RoundedRectangle(cornerRadius: 4).fill(picked).frame(width: 24, height: 24)
                    }
                    Text("将转为 \(ansiForHex(customHex)) (TrueColor)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("实时预览") {
                TextField("测试行", text: $testLine).font(.system(.caption, design: .monospaced))
                if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), !pattern.isEmpty {
                    let matches = re.matches(in: testLine, range: NSRange(testLine.startIndex..., in: testLine))
                    Text(matches.isEmpty ? "无匹配" : "\(matches.count) 处匹配")
                        .font(.caption).foregroundStyle(matches.isEmpty ? .orange : .green)
                    if !matches.isEmpty {
                        let col = useCustom ? picked : colorForCode(resolvedCode)
                        let attr = previewAttr(testLine, pattern: pattern, color: col)
                        Text(attr).font(.system(.caption, design: .monospaced))
                    }
                }
            }
            if let e = error { Text(e).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("添加") {
                    if onAdd(name, pattern, resolvedCode) { dismiss() } else { error = "正则非法" }
                }.disabled(name.isEmpty || pattern.isEmpty)
            }
        }.padding().frame(width: 520, height: 480)
    }
    func validate() { error = nil }
    func ansiForHex(_ hex: String) -> String {
        let c = Color(hex: hex)
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        let r = Int(ns.redComponent * 255), g = Int(ns.greenComponent * 255), b = Int(ns.blueComponent * 255)
        return "38;2;\(r);\(g);\(b)"
    }
    func colorForCode(_ code: String) -> Color {
        if code.hasPrefix("38;2;") {
            let p = code.split(separator: ";").compactMap { Int($0) }
            if p.count >= 5 { return Color(red: Double(p[2])/255, green: Double(p[3])/255, blue: Double(p[4])/255) }
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
    func previewAttr(_ line: String, pattern: String, color: Color) -> AttributedString {
        var a = AttributedString(line)
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return a }
        for m in re.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            if let r = Range(m.range, in: line), let ar = Range(r, in: a) { a[ar].foregroundColor = color; a[ar].font = .system(.caption, design: .monospaced).bold() }
        }
        return a
    }
}
