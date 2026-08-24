import Foundation
import SwiftTerm
import os.log

/// Asciicast v2 recorder — per-pane, file-per-session.
/// Hooks into PTYSession yieldOutput + sendInput, writes `[time, "o"/"i", data]` stream.
/// Storage: `~/Library/Application Support/Bonk/Recordings/<host>_<tab>_<pane>_<timestamp>.cast`
///
/// ## Design — byte-first, zero transform
/// * Recording branch writes the **raw** terminal bytes as UTF-8 text, with no
///   `filterOSC` / `stripCharset` / trimming / backspace simulation. TheVT
///   renderer (SwiftTerm) is responsible for interpreting escape sequences;
///   the recorder must preserve `ESC ( 0` line-drawing, H3C charset switches,
///   full-width "—", bare `\r` / `\b`, etc. verbatim.
/// * File format is asciinema `.cast` v2 (NDJSON): first line is the header
///   JSON object, every following line is a single JSON array `[time, "o"/"i", data]`.
/// * Writes are **streaming**: a dedicated serial `ioQueue` drains `FileHandle`
///   writes off the actor, so a 100 MB / ~1500-event burst never blocks the
///   feed's `Task` nor the main thread. JSON is built by hand (no
///   `JSONSerialization` per event) to avoid per-event allocations.
/// * `stop` flushes the queue synchronously before closing the handle, so no
///   tail loss on pane close.
actor SessionRecordingService {
    struct Recording: Sendable {
        let id: UUID
        let url: URL
        let host: String
        let tabID: UUID
        let paneID: UUID
        let startDate: Date
    }

    static let shared = SessionRecordingService()

    private var active: [UUID: ActiveRecording] = [:]
    // Serial I/O queue —  never on MainActor, drains FileHandle writes.
    private let ioQueue = DispatchQueue(label: "com.bonk.recording.io", qos: .utility)

    private struct ActiveRecording {
        let recording: Recording
        let startTime: CFAbsoluteTime
        var fileHandle: FileHandle
        var bytesWritten: Int = 0
        static let maxBytes = 500 * 1024 * 1024 // 500 MB cap per file
    }

    private var recordingsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Bonk/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func isRecording(paneID: UUID) -> Bool { active[paneID] != nil }

    func activeRecording(for paneID: UUID) -> Recording? { active[paneID]?.recording }

    func start(host: String, tabID: UUID, paneID: UUID, cols: Int = 80, rows: Int = 24) async throws -> Recording {
        if active[paneID] != nil { throw RecordingError.alreadyRecording }
        let safeHost = host.replacingOccurrences(of: "[^a-zA-Z0-9-_]", with: "_", options: .regularExpression)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let ts = df.string(from: Date())
        var name = "\(safeHost)_\(ts).cast"
        var url = recordingsDir.appendingPathComponent(name)
        // Ensure uniqueness when two recordings start in the same second
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            name = "\(safeHost)_\(ts)_\(counter).cast"
            url = recordingsDir.appendingPathComponent(name)
            counter += 1
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: url) else { throw RecordingError.cannotCreateFile }
        let header: [String: Any] = [
            "version": 2,
            "width": cols,
            "height": rows,
            "timestamp": Int(Date().timeIntervalSince1970),
            "env": ["TERM": "xterm-256color", "SHELL": "/bin/zsh"],
            "title": "Bonk \(host) \(tabID.uuidString.prefix(8))",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: header, options: []),
           let line = String(data: data, encoding: .utf8) {
            try? fh.write(contentsOf: (line + "\n").data(using: .utf8)!)
        }
        let startTime = CFAbsoluteTimeGetCurrent()
        var activeRec = ActiveRecording(recording: Recording(id: UUID(), url: url, host: host, tabID: tabID, paneID: paneID, startDate: Date()), startTime: startTime, fileHandle: fh)
        // Capture initial prompt line only — previous 4000-char tail caused huge blank gap + duplicated prompts
        let snapshot: String? = await MainActor.run {
            guard let cached = TerminalViewCache.shared.retrieve(paneID) else { return nil }
            guard let t = cached.view.terminal, t.cols > 0, t.rows > 0 else { return nil }
            // Prefer the current cursor line (the prompt) — trimRight false keeps "[root@...]# " spacing
            let (x, y) = t.getCursorLocation()
            if y >= 0, y < t.rows, let line = t.getLine(row: y) {
                let str = line.translateToString(trimRight: false)
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    // Return the prompt line as-is (no extra blank lines)
                    return str
                }
            }
            // Fallback: last non-empty line of buffer
            let data = t.getBufferAsData()
            guard let str = String(data: data, encoding: .utf8) else { return nil }
            let lines = str.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for line in lines.reversed() {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    return line
                }
            }
            return nil
        }
        if let snap = snapshot, !snap.isEmpty {
            let line = Self.jsonLine(time: 0.0, kind: "o", data: snap)
            let data = Data(line.utf8)
            activeRec.bytesWritten += data.count
            // Write synchronously before any future recordOutput (ioQueue is serial)
            try? fh.write(contentsOf: data)
        }
        active[paneID] = activeRec
        os_log("[REC] start %@ pane %@", log: OSLog(subsystem: "com.bonk", category: "recording"), type: .info, url.lastPathComponent, paneID.uuidString)
        return activeRec.recording
    }

    func stop(paneID: UUID) {
        guard let a = active.removeValue(forKey: paneID) else { return }
        // Drain any pending async writes before closing.
        ioQueue.sync {}
        try? a.fileHandle.close()
        os_log("[REC] stop %@ bytes %d", log: OSLog(subsystem: "com.bonk", category: "recording"), type: .info, a.recording.url.lastPathComponent, a.bytesWritten)
    }

    // MARK: - Record (raw, no transform, streaming)

    /// Record a raw output chunk. **No** OSC/DCS filtering, no charset stripping,
    /// no trimming or backspace simulation — bytes are written verbatim so
    /// `ESC ( 0` line-drawing and other VT sequences survive for faithful replay
    /// via SwiftTerm.
    func recordOutput(paneID: UUID, text: String) {
        guard var a = active[paneID] else { return }
        guard !text.isEmpty else { return }
        if a.bytesWritten > ActiveRecording.maxBytes { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - a.startTime
        let line = Self.jsonLine(time: elapsed, kind: "o", data: text)
        let data = Data(line.utf8)
        let fh = a.fileHandle
        a.bytesWritten += data.count
        active[paneID] = a
        // Off-actor serial queue — no await back-pressure, no main-thread block.
        ioQueue.async {
            try? fh.write(contentsOf: data)
        }
    }

    func recordInput(paneID: UUID, bytes: ArraySlice<UInt8>) {
        guard var a = active[paneID] else { return }
        let text = String(bytes: bytes, encoding: .utf8) ?? ""
        guard !text.isEmpty else { return }
        if a.bytesWritten > ActiveRecording.maxBytes { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - a.startTime
        let line = Self.jsonLine(time: elapsed, kind: "i", data: text)
        let data = Data(line.utf8)
        let fh = a.fileHandle
        a.bytesWritten += data.count
        active[paneID] = a
        ioQueue.async {
            try? fh.write(contentsOf: data)
        }
    }

    // MARK: - File helpers

    func listRecordings() -> [URL] {
        let dir = recordingsDir
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        return urls.filter { $0.pathExtension == "cast" }.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }

    func delete(url: URL) throws { try FileManager.default.removeItem(at: url) }

    // MARK: - Manual JSON (asciicast v2 event = [time, "o"/"i", data])

    /// Build a single NDJSON line without `JSONSerialization`.
    /// `data` is JSON-escaped so control chars, quotes, backslashes and
    /// non-ASCII survive the round-trip and can be `JSONSerialization`-decoded
    /// on playback.
    private static func jsonLine(time: Double, kind: String, data: String) -> String {
        // Keep 6 decimals — enough to preserve inter-event timing while staying
        // compatible with asciinema players; JSON numbers don't need quoting.
        let t = String(format: "%.6f", time)
        return "[\(t),\"\(kind)\",\"\(escapeJSONString(data))\"]\n"
    }

    /// Escape a string for JSON string literal (RFC 8259 §7).
    private static func escapeJSONString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00 ... 0x1F:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.append(Character(scalar))
            }
        }
        return out
    }
}

private extension URL {
    var creationDate: Date? { (try? resourceValues(forKeys: [.creationDateKey]))?.creationDate }
}

enum RecordingError: LocalizedError {
    case alreadyRecording, cannotCreateFile
    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "Already recording this pane"
        case .cannotCreateFile: return "Cannot create recording file"
        }
    }
}
