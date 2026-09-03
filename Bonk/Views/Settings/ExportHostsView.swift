import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ExportHostsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allHosts: [HostItem]
    @State private var includeSecrets = false
    @State private var showExporter = false
    @State private var exportData: Data?
    @State private var showImport = false

    var body: some View {
        Form {
            Section("导出主机配置") {
                Text("将已保存的主机导出为 JSON 文件，可分享给他人导入。SecureEnclave 凭证不支持导出。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("包含密码/私钥", isOn: $includeSecrets)
                Button("导出到文件…") {
                    prepareExport()
                    showExporter = true
                }
                .disabled(allHosts.isEmpty)
            }
            Section("导入") {
                Button("一键导入…") { showImport = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .fileExporter(
            isPresented: $showExporter,
            document: JSONDocument(data: exportData ?? Data()),
            contentType: .json,
            defaultFilename: "bonk-hosts-\(Date().formatted(.iso8601)).json"
        ) { _ in
            exportData = nil
        }
        .sheet(isPresented: $showImport) {
            UnifiedImportView(modelContext: modelContext)
        }
        .onChange(of: includeSecrets) { _, _ in prepareExport() }
        .onAppear { prepareExport() }
    }

    private func prepareExport() {
        let exports: [HostItemExport] = allHosts.compactMap { h in
            var credExport: CredentialExport?
            if let cred = h.credentialRef {
                if cred.type == .apiKey { return nil }
                var secret: String? = nil
                if includeSecrets {
                    if let s = cred.loadSecret(), !s.isEmpty { secret = s }
                    else if h.authType == .password, let s = h.loadPassword() { secret = s }
                    else if h.authType == .privateKey, let s = h.loadPrivateKey() { secret = s }
                    if h.authType == .secureEnclave { secret = nil }
                }
                credExport = CredentialExport(name: cred.name, type: cred.type.rawValue, username: cred.username, secret: secret)
            } else if includeSecrets {
                var secret: String? = nil
                if h.authType == .password { secret = h.loadPassword() }
                else if h.authType == .privateKey { secret = h.loadPrivateKey() }
                if let s = secret, !s.isEmpty {
                    credExport = CredentialExport(name: h.name, type: h.authType.rawValue, username: h.username, secret: s)
                }
            }
            return HostItemExport(name: h.name, host: h.host, port: h.port, username: h.username, authType: h.authType.rawValue, credential: credExport)
        }
        exportData = try? JSONEncoder().encode(exports)
    }
}

private struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
