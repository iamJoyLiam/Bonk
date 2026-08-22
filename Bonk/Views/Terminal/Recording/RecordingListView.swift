import SwiftUI

struct RecordingListView: View {
    @Environment(I18n.self) var i18n
    @State private var urls: [URL] = []
    @State private var playbackURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(i18n.t(.recordings)).font(.system(size: AppStyle.fontBody, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            if urls.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text(i18n.t(.noRecordingsHint))
                        .font(.system(size: AppStyle.fontSmall))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(urls, id: \.self) { url in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent).font(.system(size: AppStyle.fontSmall, design: .monospaced)).lineLimit(1)
                                Text(fileInfo(url)).font(.system(size: AppStyle.fontCaption)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(i18n.t(.play)) { openPlayback(url) }
                                .buttonStyle(.bordered).controlSize(.small)
                            Button(i18n.t(.share)) { share(url) }
                                .buttonStyle(.bordered).controlSize(.small)
                            Button(i18n.t(.delete)) { delete(url) }.tint(.red).buttonStyle(.bordered).controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }.frame(minHeight: 200)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 300, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { reload() }
    }

    private func fileInfo(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let date = (attrs?[.creationDate] as? Date) ?? Date()
        let fmt = ByteCountFormatter(); fmt.countStyle = .file
        let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short
        return "\(fmt.string(fromByteCount: Int64(size))) · \(df.string(from: date))"
    }
    private func reload() {
        Task { urls = await SessionRecordingService.shared.listRecordings() }
    }
    private func delete(_ url: URL) {
        Task { try? await SessionRecordingService.shared.delete(url: url); reload() }
    }
    private func share(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    private func openPlayback(_ url: URL) {
        let view = RecordingPlaybackView(url: url).environment(i18n)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = url.lastPathComponent
        window.setContentSize(NSSize(width: 700, height: 480))
        window.styleMask.insert([.resizable, .closable, .titled])
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
