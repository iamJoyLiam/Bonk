import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ExportHostsView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @Query private var allHosts: [HostItem]
    @State private var includeSecrets = false
    @State private var showExporter = false
    @State private var exportData: Data?
    @State private var showImport = false

    var body: some View {
        Form {
            Section(i18n.t(.exportHostsTitle)) {
                Text(i18n.t(.exportHostsDesc))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(i18n.t(.exportIncludeSecrets), isOn: $includeSecrets)
                Button(i18n.t(.exportToFile)) {
                    prepareExport()
                    showExporter = true
                }
                .disabled(allHosts.isEmpty)
            }
            Section(i18n.t(.importSection)) {
                Button(i18n.t(.quickImport)) { showImport = true }
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
        let exports: [HostItemExport] = allHosts.compactMap { host in
            var credExport: CredentialExport?
            if let cred = host.credentialRef {
                if cred.type == .apiKey { return nil }
                var secret: String? = nil
                if includeSecrets {
                    if let sessionState = cred.loadSecret(), !sessionState.isEmpty { secret = sessionState }
                    else if host.authType == .password, let sessionState = host.loadPassword() { secret = sessionState }
                    else if host.authType == .privateKey, let sessionState = host.loadPrivateKey() { secret = sessionState }
                    if host.authType == .secureEnclave { secret = nil }
                }
                credExport = CredentialExport(name: cred.name, type: cred.type.rawValue, username: cred.username, secret: secret)
            } else if includeSecrets {
                var secret: String? = nil
                if host.authType == .password { secret = host.loadPassword() }
                else if host.authType == .privateKey { secret = host.loadPrivateKey() }
                if let sessionState = secret, !sessionState.isEmpty {
                    credExport = CredentialExport(name: host.name, type: host.authType.rawValue, username: host.username, secret: sessionState)
                }
            }
            return HostItemExport(name: host.name, host: host.host, port: host.port, username: host.username, authType: host.authType.rawValue, credential: credExport)
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
