import SwiftUI

struct RecordingListView: View {
    @Environment(I18n.self) var i18n
    @State private var urls: [URL] = []
    @State private var pendingDelete: URL?

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            if urls.isEmpty {
                emptyStateView
            } else {
                recordingList
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .onAppear { reload() }
        .alert(i18n.t(.delete), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(i18n.t(.cancel), role: .cancel) { pendingDelete = nil }
            Button(i18n.t(.delete), role: .destructive) {
                if let url = pendingDelete { delete(url) }
                pendingDelete = nil
            }
        } message: {
            if let url = pendingDelete {
                Text(playbackDisplayName(for: url))
            }
        }
    }

    // MARK: - Header — same plain style as workspace

    private var headerSection: some View {
        HStack {
            Image(systemName: "recordingtape")
                .font(.title2)
                .foregroundStyle(.blue)
            Text(i18n.t(.recordings))
                .font(.headline)
            Spacer()
            Text(i18n.tr(.workspaceCount, args: urls.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "recordingtape")
                .font(.system(size: AppStyle.fontDisplay))
                .foregroundStyle(.tertiary)
            Text(i18n.t(.noRecordings))
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(i18n.t(.noRecordingsHint))
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: AppStyle.panelWidthSmall)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List — plain rows (not cards), native icon buttons

    private var recordingList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(urls, id: \.self) { url in
                    recordingRow(url)
                    if url != urls.last {
                        Divider()
                            .padding(.leading, AppStyle.spacingSidebar)
                    }
                }
            }
        }
    }

    private func recordingRow(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "recordingtape")
                .foregroundStyle(.blue)
                .frame(width: AppStyle.buttonMedium)

            VStack(alignment: .leading, spacing: 3) {
                Text(playbackDisplayName(for: url))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(fileInfo(url))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            HStack(spacing: AppStyle.spacingXS) {
                Button { openPlayback(url) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: AppStyle.fontSmall, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: AppStyle.buttonMedium, height: AppStyle.buttonMedium)
                        .background(Circle().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .help(i18n.t(.play))

                Button { share(url) } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: AppStyle.fontSmall))
                        .foregroundStyle(.secondary)
                        .frame(width: AppStyle.buttonMedium, height: AppStyle.buttonMedium)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(AppStyle.opacityStroke), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(i18n.t(.share))

                Button { pendingDelete = url } label: {
                    Image(systemName: "trash")
                        .font(.system(size: AppStyle.fontSmall))
                        .foregroundStyle(.red.opacity(0.9))
                        .frame(width: AppStyle.buttonMedium, height: AppStyle.buttonMedium)
                        .background(Circle().fill(Color.red.opacity(0.08)))
                        .overlay(Circle().strokeBorder(Color.red.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(i18n.t(.delete))
            }
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingML)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openPlayback(url) }
        .contextMenu {
            Button { openPlayback(url) } label: { Label(i18n.t(.play), systemImage: "play.circle") }
            Button { share(url) } label: { Label(i18n.t(.share), systemImage: "square.and.arrow.up") }
            Divider()
            Button(role: .destructive) { pendingDelete = url } label: { Label(i18n.t(.delete), systemImage: "trash") }
        }
    }

    // MARK: - Helpers — keep human-readable naming fix

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

    private func playbackDisplayName(for url: URL) -> String {
        let raw = url.deletingPathExtension().lastPathComponent
        if let range = raw.range(of: "_\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2}", options: .regularExpression) {
            return String(raw[..<range.lowerBound])
        }
        if let range = raw.range(of: "_\\d{4}-\\d{2}-\\d{2}T", options: .regularExpression) {
            let prefix = String(raw[..<range.lowerBound])
            if let first = prefix.firstIndex(of: "_") {
                return String(prefix[..<first])
            }
            return prefix
        }
        if let idx = raw.firstIndex(of: "_") {
            return String(raw[..<idx])
        }
        return raw
    }

    private static func formattedLegacyDate(_ ts: String) -> String? {
        guard let tIdx = ts.firstIndex(of: "T") else { return nil }
        let datePart = String(ts[..<tIdx])
        var timePart = String(ts[ts.index(after: tIdx)...])
        let hasZ = timePart.hasSuffix("Z")
        if hasZ { timePart = String(timePart.dropLast()) }
        timePart = timePart.replacingOccurrences(of: "-", with: ":")
        let iso = "\(datePart)T\(timePart)\(hasZ ? "Z" : "")"
        if let date = ISO8601DateFormatter().date(from: iso) {
            let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
            return df.string(from: date)
        }
        return nil
    }

    private func openPlayback(_ url: URL) {
        let view = RecordingPlaybackView(url: url).environment(i18n)
        let hostingView = NSHostingView(rootView: view)
        hostingView.autoresizingMask = [.width, .height]
        let contentSize = NSSize(width: 760, height: 520)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.title = "\(playbackDisplayName(for: url))"
        window.subtitle = fileInfo(url)
        window.representedURL = url
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.setContentSize(contentSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
