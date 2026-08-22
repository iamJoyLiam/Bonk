import SwiftUI

struct RecordingPlaybackView: View {
    @Environment(I18n.self) var i18n
    let url: URL
    @State private var output: String = ""
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(url.lastPathComponent).font(.system(size: AppStyle.fontSmall, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if isPlaying {
                    Button(i18n.t(.pause)) { task?.cancel(); isPlaying = false }.buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button(output.isEmpty ? i18n.t(.play) : i18n.t(.replay)) { play() }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button(i18n.t(.close)) { task?.cancel(); NSApp.keyWindow?.close() }.buttonStyle(.bordered).controlSize(.small)
            }
            ProgressView(value: progress).progressViewStyle(.linear)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(AppStyle.opacityStroke)))
                ScrollView {
                    if output.isEmpty && !isPlaying {
                        Text(i18n.t(.noRecordingsHint)).font(.system(size: AppStyle.fontSmall)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    } else {
                        Text(output.isEmpty ? " " : output).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(8)
                    }
                }
            }
            .frame(minHeight: 300)
        }
        .padding(16).frame(minWidth: 600, minHeight: 400)
        .onDisappear { task?.cancel() }
        .onAppear { if output.isEmpty { play() } }
    }

    private func play() {
        task?.cancel(); output = ""; progress = 0; isPlaying = true
        task = Task {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { isPlaying = false; return }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count > 1 else { isPlaying = false; return }
            // line 0 is header, rest are [time, "o"/"i", data]
            struct Ev { let t: Double; let data: String }
            var events: [Ev] = []
            for line in lines.dropFirst() {
                guard let data = line.data(using: .utf8),
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                      arr.count == 3,
                      let t = arr[0] as? Double,
                      let kind = arr[1] as? String, kind == "o",
                      let d = arr[2] as? String else { continue }
                let clean = PTYSession.filterOSCSequences(d)
                if clean.isEmpty && !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // pure OSC title, skip
                    continue
                }
                events.append(Ev(t: t, data: clean.isEmpty ? d : clean))
            }
            let total = events.last?.t ?? 1
            var lastT: Double = 0
            for ev in events {
                if Task.isCancelled { break }
                let dt = ev.t - lastT
                // cap idle gaps to 1s to avoid long waits, keep timing feel
                let sleep = min(dt, 1.0)
                if sleep > 0.01 { try? await Task.sleep(for: .seconds(sleep)) }
                if Task.isCancelled { break }
                output += ev.data
                progress = total > 0 ? min(1, ev.t / total) : 1
                lastT = ev.t
            }
            isPlaying = false; progress = 1
        }
    }
}
