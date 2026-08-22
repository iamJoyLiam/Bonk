import Foundation
import os.log

/// Asciicast v2 recorder — per-pane, file-per-session.
/// Hooks into PTYSession yieldOutput + sendInput, writes `[time, "o"/"i", data]` stream.
/// Storage: `~/Library/Application Support/Bonk/Recordings/<host>_<tab>_<pane>_<timestamp>.cast`
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

    private var active: [UUID: ActiveRecording] = [:] // paneID -> recording
    private var fileHandles: [UUID: FileHandle] = [:]

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

    func start(host: String, tabID: UUID, paneID: UUID, cols: Int = 80, rows: Int = 24) throws -> Recording {
        if active[paneID] != nil { throw RecordingError.alreadyRecording }
        let safeHost = host.replacingOccurrences(of: "[^a-zA-Z0-9-_]", with: "_", options: .regularExpression)
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "\(safeHost)_\(tabID.uuidString.prefix(8))_\(paneID.uuidString.prefix(8))_\(ts).cast"
        let url = recordingsDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: url) else { throw RecordingError.cannotCreateFile }
        let header: [String: Any] = [
            "version": 2,
            "width": cols,
            "height": rows,
            "timestamp": Int(Date().timeIntervalSince1970),
            "env": ["TERM": "xterm-256color", "SHELL": "/bin/zsh"],
            "title": "Bonk \(host) \(tabID.uuidString.prefix(8))"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: header, options: []),
           let line = String(data: data, encoding: .utf8) {
            try? fh.write(contentsOf: (line + "\n").data(using: .utf8)!)
        }
        let rec = Recording(id: UUID(), url: url, host: host, tabID: tabID, paneID: paneID, startDate: Date())
        active[paneID] = ActiveRecording(recording: rec, startTime: CFAbsoluteTimeGetCurrent(), fileHandle: fh)
        os_log("[REC] start %@ pane %@", log: OSLog(subsystem: "com.bonk", category: "recording"), type: .info, url.lastPathComponent, paneID.uuidString)
        return rec
    }

    func stop(paneID: UUID) {
        guard let a = active.removeValue(forKey: paneID) else { return }
        try? a.fileHandle.close()
        os_log("[REC] stop %@ bytes %d", log: OSLog(subsystem: "com.bonk", category: "recording"), type: .info, a.recording.url.lastPathComponent, a.bytesWritten)
    }

    func recordOutput(paneID: UUID, text: String) {
        guard var a = active[paneID] else { return }
        guard !text.isEmpty else { return }
        if a.bytesWritten > ActiveRecording.maxBytes { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - a.startTime
        // asciicast v2: [time, "o", data] single JSON line
        let event: [Any] = [elapsed, "o", text]
        if let data = try? JSONSerialization.data(withJSONObject: event, options: []),
           let line = String(data: data, encoding: .utf8) {
            let bytes = (line + "\n").data(using: .utf8)!
            try? a.fileHandle.write(contentsOf: bytes)
            a.bytesWritten += bytes.count
            active[paneID] = a
        }
    }

    func recordInput(paneID: UUID, bytes: ArraySlice<UInt8>) {
        guard var a = active[paneID] else { return }
        let text = String(bytes: bytes, encoding: .utf8) ?? ""
        guard !text.isEmpty else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - a.startTime
        let event: [Any] = [elapsed, "i", text]
        if let data = try? JSONSerialization.data(withJSONObject: event, options: []),
           let line = String(data: data, encoding: .utf8) {
            let b = (line + "\n").data(using: .utf8)!
            try? a.fileHandle.write(contentsOf: b)
            a.bytesWritten += b.count
            active[paneID] = a
        }
    }

    func listRecordings() -> [URL] {
        let dir = recordingsDir
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        return urls.filter { $0.pathExtension == "cast" }.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }

    func delete(url: URL) throws { try FileManager.default.removeItem(at: url) }
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
