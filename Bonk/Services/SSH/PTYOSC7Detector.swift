import Foundation
import os.log

/// Detects OSC 7 sequences in a byte stream and extracts the working directory.
/// Thread-safe: all mutable state protected by NSLock.
/// Callbacks execute outside the lock to prevent deadlocks.
final class PTYOSC7Detector: @unchecked Sendable {
    var onCWDChange: ((String) -> Void)?

    private enum State {
        case idle, gotESC, gotBracket, got7, gotSemicolon, collectingURL
    }

    private let lock = NSLock()
    private var state: State = .idle
    private var urlBuffer: [UInt8] = []
    private static let maxURLBytes = 4096 // Prevent unbounded growth on malformed sequences

    func process(_ data: [UInt8]) {
        // Collect CWDs inside lock, fire callbacks outside
        var detectedCWDs: [String] = []

        lock.lock()
        for byte in data {
            switch state {
            case .idle:
                if byte == 0x1B { state = .gotESC }
            case .gotESC:
                state = byte == 0x5D ? .gotBracket : .idle
            case .gotBracket:
                state = byte == 0x37 ? .got7 : .idle
            case .got7:
                if byte == 0x3B {
                    state = .gotSemicolon
                    urlBuffer.removeAll(keepingCapacity: true)
                } else {
                    state = .idle
                }
            case .gotSemicolon:
                if byte == 0x07 {
                    if let cwd = extractCWD() { detectedCWDs.append(cwd) }
                    state = .idle
                } else if byte == 0x1B {
                    if let cwd = extractCWD() { detectedCWDs.append(cwd) }
                    state = .gotESC
                } else {
                    urlBuffer.append(byte)
                    state = .collectingURL
                }
            case .collectingURL:
                if byte == 0x07 {
                    if let cwd = extractCWD() { detectedCWDs.append(cwd) }
                    state = .idle
                } else if byte == 0x1B {
                    if let cwd = extractCWD() { detectedCWDs.append(cwd) }
                    state = .gotESC
                } else if urlBuffer.count < Self.maxURLBytes {
                    urlBuffer.append(byte)
                }
            }
        }
        lock.unlock()

        // Fire callbacks outside lock — safe for any amount of work
        for cwd in detectedCWDs {
            onCWDChange?(cwd)
        }
    }

    func process(_ text: String) {
        process(Array(text.utf8))
    }

    /// Must be called while holding `lock`.
    private func extractCWD() -> String? {
        guard !urlBuffer.isEmpty else { return nil }
        let urlString = String(bytes: urlBuffer, encoding: .utf8) ?? ""
        urlBuffer.removeAll(keepingCapacity: true)
        guard urlString.hasPrefix("file://") else { return nil }
        let afterScheme = urlString.dropFirst(7)
        if let slashIndex = afterScheme.firstIndex(of: "/") {
            let path = String(afterScheme[afterScheme.index(after: slashIndex)...])
            let cwd = "/" + path
            Log.ssh.debug("OSC 7 CWD detected: \(cwd)")
            return cwd
        }
        return nil
    }
}
