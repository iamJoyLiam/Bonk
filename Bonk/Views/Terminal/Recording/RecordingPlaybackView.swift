import AppKit
import SwiftTerm
import SwiftUI

struct PlaybackEvent: Sendable { let time: Double; let data: String }

struct RecordingPlaybackView: View {
    @Environment(I18n.self) var i18n
    let url: URL
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var speed: Double = 1.0
    @State private var task: Task<Void, Never>?
    @State private var terminalView: SwiftTerm.TerminalView?
    @State private var headerTitle: String = ""
    @State private var hasStarted = false
    @State private var isHoveringControls = false
    @State private var cachedEvents: [PlaybackEvent]?
    @State private var totalDuration: Double = 1
    @State private var nextIndex = 0
    @State private var lastEventTime: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            // ── Top bar ──
            HStack(spacing: AppStyle.spacingL) {
                // Left: icon + title — plain hero icon (no rounded-rect background, matches PanelHeaderView)
                HStack(spacing: AppStyle.spacingM) {
                    Image(systemName: "recordingtape")
                        .font(.system(size: AppStyle.fontMedium, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: AppStyle.iconHero, height: AppStyle.iconHero)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playbackDisplayName)
                            .font(.system(size: AppStyle.fontRegular, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !headerTitle.isEmpty {
                            Text(headerTitle)
                                .font(.system(size: AppStyle.fontCaption))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(fileSubtitle)
                                .font(.system(size: AppStyle.fontCaption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                // Speed pill
                HStack(spacing: AppStyle.spacingXS) {
                    Button { speed = max(0.25, speed - 0.25) } label: {
                        Image(systemName: "minus")
                            .font(.system(size: AppStyle.fontCaption, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                    .disabled(speed <= 0.25)

                    Text("×\(String(format: "%.2g", speed))")
                        .font(.system(size: AppStyle.fontSmall, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(width: 38)
                        .monospacedDigit()

                    Button { speed = min(5, speed + 0.25) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: AppStyle.fontCaption, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                    .disabled(speed >= 5)
                }
                .padding(.horizontal, AppStyle.spacingS)
                .padding(.vertical, AppStyle.spacingXS)
                .background(
                    Capsule()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(AppStyle.opacityStroke), lineWidth: 1))
                )

                // Play / Pause — supports pause/resume (not just replay)
                Button {
                    if isPlaying {
                        task?.cancel()
                        isPlaying = false
                    } else {
                        if progress >= 1 {
                            // finished -> replay from start
                            nextIndex = 0
                            lastEventTime = 0
                            progress = 0
                            terminalView?.terminal.resetToInitialState()
                            terminalView?.clearScrollback()
                        }
                        play()
                    }
                } label: {
                    let isFinished = progress >= 1
                    let isResume = !isPlaying && hasStarted && !isFinished && nextIndex > 0
                    HStack(spacing: AppStyle.spacingXS) {
                        Image(systemName: isPlaying ? "pause.fill" : (isFinished ? "arrow.counterclockwise" : "play.fill"))
                            .font(.system(size: AppStyle.fontSmall, weight: .semibold))
                        Text(isPlaying ? i18n.t(.pause) : (isFinished ? i18n.t(.replay) : i18n.t(.play)))
                            .font(.system(size: AppStyle.fontSmall, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, AppStyle.spacingXL)
                    .padding(.vertical, AppStyle.spacingSPlus)
                    .background(Capsule().fill(isPlaying ? Color.orange : Color.accentColor))
                    .shadow(color: (isPlaying ? Color.orange : Color.accentColor).opacity(0.25), radius: 6, y: 2)
                }
                .buttonStyle(.plain)

                Button { task?.cancel(); NSApp.keyWindow?.close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: AppStyle.fontSmall, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: AppStyle.buttonMedium, height: AppStyle.buttonMedium)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(AppStyle.opacityStroke), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(i18n.t(.close))
            }
            .padding(.horizontal, AppStyle.spacingXL)
            .padding(.vertical, AppStyle.spacingML)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Progress — thin, accent
            PanelProgressBar(progress: progress)
                .padding(.horizontal, AppStyle.spacingXL)
                .padding(.vertical, AppStyle.spacingS)

            // Terminal canvas
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(color: Color.black.opacity(0.06), radius: 12, y: 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous)
                            .strokeBorder(Color.primary.opacity(AppStyle.opacityStroke), lineWidth: 1)
                    )
                PlaybackTerminalBridge(terminalView: $terminalView)
                    .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous))
                    .padding(1)
            }
            .padding(.horizontal, AppStyle.spacingXL)
            .padding(.bottom, AppStyle.spacingXL)
            .frame(minHeight: 360)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { task?.cancel() }
        .onAppear {
            parseHeader()
            if !hasStarted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { play() }
            }
        }
        .onChange(of: terminalView != nil) { _, ready in
            if ready, !hasStarted, !isPlaying { play() }
        }
    }

    private var fileSubtitle: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let fmt = ByteCountFormatter(); fmt.countStyle = .file
        return fmt.string(fromByteCount: Int64(size))
    }

    private var playbackDisplayName: String {
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

    private static func formattedLegacyDate(_ timestamp: String) -> String? {
        guard let tIdx = timestamp.firstIndex(of: "T") else { return nil }
        let datePart = String(timestamp[..<tIdx])
        var timePart = String(timestamp[timestamp.index(after: tIdx)...])
        let hasZ = timePart.hasSuffix("Z")
        if hasZ { timePart = String(timePart.dropLast()) }
        timePart = timePart.replacingOccurrences(of: "-", with: ":")
        let iso = "\(datePart)T\(timePart)\(hasZ ? "Z" : "")"
        if let date = ISO8601DateFormatter().date(from: iso) {
            let dateFormatter = DateFormatter(); dateFormatter.dateStyle = .medium; dateFormatter.timeStyle = .short
            return dateFormatter.string(from: date)
        }
        return nil
    }

    private func parseHeader() {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let firstLine = content.split(separator: "\n", omittingEmptySubsequences: false).first
        guard let line = firstLine, let data = String(line).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let title = obj["title"] as? String { headerTitle = title }
    }

    // swiftlint:disable:next function_body_length
    private func play() {
        guard let targetTerminal = terminalView else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { play() }
            return
        }
        task?.cancel()
        hasStarted = true
        isPlaying = true

        let shouldReset = nextIndex == 0 && progress == 0
        if shouldReset {
            progress = 0
            targetTerminal.terminal.resetToInitialState()
            targetTerminal.clearScrollback()
        }

        task = Task {
            let captureURL = url
            // Parse once and cache
            let events: [PlaybackEvent]
            let total: Double
            let cached = await MainActor.run { self.cachedEvents }
            if let cached, !cached.isEmpty {
                events = cached
                total = await MainActor.run { self.totalDuration }
            } else {
                let parsed: (events: [PlaybackEvent], total: Double)? = await Task
                    .detached(priority: .userInitiated) { () -> (events: [PlaybackEvent], total: Double)? in
                        guard let content = try? String(contentsOf: captureURL, encoding: .utf8) else { return nil }
                        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                        guard lines.count > 1 else { return nil }
                        var evs: [PlaybackEvent] = []
                        evs.reserveCapacity(lines.count - 1)
                        for line in lines.dropFirst() {
                            if line.isEmpty { continue }
                            guard let data = line.data(using: .utf8),
                                  let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                                  array.count == 3,
                                  let timestamp = array[0] as? Double,
                                  let kind = array[1] as? String, kind == "o",
                                  let payload = array[2] as? String
                            else { continue }
                            evs.append(PlaybackEvent(time: timestamp, data: payload))
                        }
                        let totalTime = evs.last?.time ?? 1
                        return (evs, totalTime)
                    }.value
                guard let parsed else {
                    await MainActor.run { isPlaying = false }
                    return
                }
                events = parsed.events
                total = parsed.total
                await MainActor.run {
                    self.cachedEvents = events
                    self.totalDuration = total
                }
            }
            var lastTime: Double = await MainActor.run { self.lastEventTime }
            var idx: Int = await MainActor.run { self.nextIndex }
            // Clamp in case of reload
            if idx >= events.count { idx = 0; lastTime = 0 }
            for index in idx..<events.count {
                if Task.isCancelled { break }
                let event = events[index]
                let currentSpeed = await MainActor.run { speed }
                let denom = max(currentSpeed, 0.05)
                let delta = (event.time - lastTime) / denom
                let sleep = min(delta, 1.0 / denom)
                if sleep > 0.01 { try? await Task.sleep(for: .seconds(sleep)) }
                if Task.isCancelled { break }
                await MainActor.run {
                    targetTerminal.feed(text: event.data)
                    progress = total > 0 ? min(1, event.time / total) : 1
                    nextIndex = index + 1
                    lastEventTime = event.time
                }
                lastTime = event.time
            }
            let wasCancelled = Task.isCancelled
            await MainActor.run {
                isPlaying = false
                if !wasCancelled {
                    progress = 1
                    // keep nextIndex at end so next play triggers replay
                }
            }
        }
    }
}

// MARK: - Terminal bridge (isolated scrollback, read-only)

private struct PlaybackTerminalBridge: NSViewRepresentable {
    @Binding var terminalView: SwiftTerm.TerminalView?

    func makeNSView(context: Context) -> NSScrollView {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let terminal = SwiftTerm.TerminalView(
            frame: NSRect(x: 0, y: 0, width: 740, height: 420),
            font: font
        )
        // Apply current app theme so playback is white in light mode (not black default)
        terminal.configureNativeColors()
        let scheme = TerminalThemeManager.shared.resolve()
        applyColorScheme(to: terminal, scheme: scheme)
        // Keep in sync when user switches theme while playback window is open
        context.coordinator.observe(terminal: terminal)
        let scroll = NSScrollView()
        scroll.documentView = terminal
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        // Inset content so text never kisses the rounded border was
        scroll.contentInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        scroll.automaticallyAdjustsContentInsets = false
        // Match scrollView background to terminal so no dark gutter shows
        scroll.backgroundColor = scheme.background.nsColor
        DispatchQueue.main.async { terminalView = terminal }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let terminal = nsView.documentView as? SwiftTerm.TerminalView else { return }
        let scheme = TerminalThemeManager.shared.resolve()
        // Re-apply on every SwiftUI update — cheap and keeps light/dark in sync
        applyColorScheme(to: terminal, scheme: scheme)
        nsView.backgroundColor = scheme.background.nsColor
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject {
        private var observer: NSObjectProtocol?
        private weak var terminal: SwiftTerm.TerminalView?
        func observe(terminal: SwiftTerm.TerminalView) {
            self.terminal = terminal
            observer = NotificationCenter.default.addObserver(forName: .terminalThemeDidChange, object: nil, queue: .main) { [weak self] note in
                guard let self, let terminalView = self.terminal else { return }
                if let scheme = note.object as? TerminalColorScheme {
                    applyColorScheme(to: terminalView, scheme: scheme)
                    (terminalView.enclosingScrollView as? NSScrollView)?.backgroundColor = scheme.background.nsColor
                } else {
                    let scheme = TerminalThemeManager.shared.resolve()
                    applyColorScheme(to: terminalView, scheme: scheme)
                    (terminalView.enclosingScrollView as? NSScrollView)?.backgroundColor = scheme.background.nsColor
                }
            }
        }
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
