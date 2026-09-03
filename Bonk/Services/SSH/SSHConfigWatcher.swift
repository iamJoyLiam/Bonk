import Foundation
import os.log

/// Watches ~/.ssh/config (and its Include expansions) and posts a notification when it changes.
/// Minimal MVP: watches main file only; Include expansion re-evaluated on each event.
final class SSHConfigWatcher: @unchecked Sendable {
    static let shared = SSHConfigWatcher()
    static let didChangeNotification = Notification.Name("SSHConfigWatcher.didChange")

    private let logger = Logger(subsystem: "com.bonk", category: "SSHConfigWatcher")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fds: [Int32] = []
    private var debounceWork: DispatchWorkItem?
    private var isRunning = false

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true
        watch(paths: collectWatchPaths())
        logger.info("SSHConfigWatcher started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for src in sources { src.cancel() }
        sources.removeAll()
        for fdValue in fds { close(fdValue) }
        fds.removeAll()
        debounceWork?.cancel()
        logger.info("SSHConfigWatcher stopped")
    }

    func restart() {
        stop()
        start()
    }

    // MARK: - Private

    private func collectWatchPaths() -> [String] {
        var paths: [String] = []
        let main = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
        paths.append(main)
        // Expand Include directives (reuse parser)
        if let content = try? String(contentsOfFile: main, encoding: .utf8) {
            // Quick scan for Include lines
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let lower = trimmed.lowercased()
                if lower.hasPrefix("include ") || lower.hasPrefix("include=") {
                    let after = trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "=", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    let patterns = after.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    for pat in patterns {
                        let expanded = expandPattern(pat, relativeTo: (main as NSString).deletingLastPathComponent)
                        paths.append(contentsOf: expanded)
                    }
                }
            }
        }
        return Array(Set(paths))
    }

    private func expandPattern(_ pattern: String, relativeTo base: String) -> [String] {
        var pat = pattern
        if pat.hasPrefix("~/") { pat = (NSHomeDirectory() as NSString).appendingPathComponent(String(pat.dropFirst(2))) }
        else if pat.hasPrefix("~") { pat = (NSHomeDirectory() as NSString).appendingPathComponent(String(pat.dropFirst(1))) }
        else if !pat.hasPrefix("/") { pat = (base as NSString).appendingPathComponent(pat) }
        // Use glob
        var gtValue = glob_t()
        let ret = glob(pat, GLOB_TILDE | GLOB_BRACE | GLOB_MARK, nil, &gtValue)
        defer { globfree(&gtValue) }
        guard ret == 0 else { return [] }
        var out: [String] = []
        for index in 0..<Int(gtValue.gl_pathc) {
            if let cstr = gtValue.gl_pathv[index], let str = String(validatingUTF8: cstr) {
                // glob with GLOB_MARK appends / for dirs — skip dirs
                if str.hasSuffix("/") { continue }
                out.append(str)
            }
        }
        return out
    }

    private func watch(paths: [String]) {
        for path in paths {
            let fdValue = open(path, O_EVTONLY)
            if fdValue < 0 { continue }
            fds.append(fdValue)
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fdValue, eventMask: [.write, .rename, .delete, .extend], queue: .global(qos: .utility))
            src.setEventHandler { [weak self] in self?.onEvent() }
            src.setCancelHandler { close(fdValue) }
            src.resume()
            sources.append(src)
        }
        // If main file didn't exist, watch its directory for creation
        let main = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
        if !FileManager.default.fileExists(atPath: main) {
            let dir = (main as NSString).deletingLastPathComponent
            let fdValue = open(dir, O_EVTONLY)
            if fdValue >= 0 {
                fds.append(fdValue)
                let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fdValue, eventMask: [.write, .extend], queue: .global(qos: .utility))
                src.setEventHandler { [weak self] in self?.onEvent() }
                src.setCancelHandler { close(fdValue) }
                src.resume()
                sources.append(src)
            }
        }
    }

    private func onEvent() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.logger.info("ssh config change detected")
            // Re-collect includes (new files may have appeared)
            self.stop()
            self.isRunning = true
            self.watch(paths: self.collectWatchPaths())
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
        debounceWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}
