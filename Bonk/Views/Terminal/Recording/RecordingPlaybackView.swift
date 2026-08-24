import AppKit
import SwiftTerm
import SwiftUI

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.system(size: AppStyle.fontSmall, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !headerTitle.isEmpty {
                        Text(headerTitle)
                            .font(.system(size: AppStyle.fontCaption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    Text("×\(String(format: "%.2g", speed))")
                        .font(.system(size: AppStyle.fontCaption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                    Slider(value: $speed, in: 0.25 ... 5, step: 0.25)
                        .frame(width: 90)
                }
                if isPlaying {
                    Button(i18n.t(.pause)) { task?.cancel(); isPlaying = false }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button(hasStarted ? i18n.t(.replay) : i18n.t(.play)) { play() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button(i18n.t(.close)) { task?.cancel(); NSApp.keyWindow?.close() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(AppStyle.opacityStroke)))
                // SwiftTerm handles \b, \r, ESC[K, ESC(0, OSC 0, ESC[A etc. natively.
                // No manual backspace / filterOSC — feed raw bytes directly.
                PlaybackTerminalBridge(terminalView: $terminalView)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(minHeight: 320)
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 480)
        .onDisappear { task?.cancel() }
        .onAppear {
            parseHeader()
            // Wait one runloop for the TerminalView to be created
            if !hasStarted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { play() }
            }
        }
        .onChange(of: terminalView != nil) { _, ready in
            if ready, !hasStarted, !isPlaying { play() }
        }
    }

    private func parseHeader() {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let firstLine = content.split(separator: "\n", omittingEmptySubsequences: false).first
        guard let line = firstLine, let data = String(line).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let title = obj["title"] as? String { headerTitle = title }
        // width/height are honoured by the TerminalView's frame once created; no manual cols set needed
    }

    private func play() {
        guard let tv = terminalView else {
            // View not ready yet — retry shortly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { play() }
            return
        }
        task?.cancel()
        hasStarted = true
        isPlaying = true
        progress = 0
        // Reset to initial VT state — mirrors SwiftTerm's termcast reset
        tv.terminal.resetToInitialState()
        // Clear scrollback so replay starts from a blank screen
        tv.clearScrollback()

        task = Task {
            struct Ev { let t: Double; let data: String }
            let captureURL = url
            let parsed: (events: [Ev], total: Double)? = await Task.detached(priority: .userInitiated) { () -> (events: [Ev], total: Double)? in
                guard let content = try? String(contentsOf: captureURL, encoding: .utf8) else { return nil }
                let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
                guard lines.count > 1 else { return nil }
                var events: [Ev] = []
                events.reserveCapacity(lines.count - 1)
                for line in lines.dropFirst() {
                    if line.isEmpty { continue }
                    guard let data = line.data(using: .utf8),
                          let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          arr.count == 3,
                          let t = arr[0] as? Double,
                          let kind = arr[1] as? String, kind == "o",
                          let d = arr[2] as? String
                    else { continue }
                    // Byte-first, zero transform — keep OSC, CSI, charset, \b, \r verbatim
                    events.append(Ev(t: t, data: d))
                }
                let total = events.last?.t ?? 1
                return (events, total)
            }.value
            guard let parsed else {
                await MainActor.run { isPlaying = false }
                return
            }
            let events = parsed.events
            let total = parsed.total
            var lastT: Double = 0
            for ev in events {
                if Task.isCancelled { break }
                let currentSpeed = await MainActor.run { speed }
                let denom = max(currentSpeed, 0.05)
                let dt = (ev.t - lastT) / denom
                let sleep = min(dt, 1.0 / denom)
                if sleep > 0.01 { try? await Task.sleep(for: .seconds(sleep)) }
                if Task.isCancelled { break }
                // Direct feed — SwiftTerm parses \b as destructive backspace,
                // \r as carriage return, ESC[K as erase-in-line, ESC(0 as line-drawing charset,
                // ESC[A as cursor up, and ESC]0;… as title (not rendered), so the
                // “docker\u{8}[K” sequences that broke the old Text+= path disappear.
                await MainActor.run {
                    tv.feed(text: ev.data)
                    progress = total > 0 ? min(1, ev.t / total) : 1
                }
                lastT = ev.t
            }
            await MainActor.run {
                isPlaying = false
                progress = 1
            }
        }
    }
}

// MARK: - Terminal bridge (isolated scrollback, read-only)

private struct PlaybackTerminalBridge: NSViewRepresentable {
    @Binding var terminalView: SwiftTerm.TerminalView?

    func makeNSView(context: Context) -> NSScrollView {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let tv = SwiftTerm.TerminalView(frame: NSRect(x: 0, y: 0, width: 680, height: 400), font: font)
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        DispatchQueue.main.async { terminalView = tv }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject {}
}
