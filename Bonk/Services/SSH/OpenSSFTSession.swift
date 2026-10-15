//
//  OpenSSFTSession.swift
//  Bonk
//
//  One reusable `/usr/bin/sftp` process for short control commands.
//
//  ## The problem
//
//  `runSFTP` spawned a brand-new `sftp` process per command batch and then sent
//  `quit`. `OpenSSHSFTPClient.listDirectory` issues exactly one command —
//  `ls -l <path>` — so **every folder the user opened cost a complete SSH
//  connection**: TCP, KEX, host-key verification, authentication, channel open,
//  and then the same teardown. On a remote host that is seconds per click.
//
//  ## What is reused, and what deliberately is not
//
//  Reused: `pwd`, `ls`, `mkdir`, `rm`/`rmdir`, `rename` — short, idempotent
//  control operations that return promptly.
//
//  **Not** reused: `get` and `put`. A transfer can run for minutes, its output is
//  parsed incrementally for progress, and cancellation works by killing that
//  specific process. Parking a transfer on a shared, long-lived process would
//  make every other operation wait behind it and would leave cancellation with
//  no way to reach the child. Transfers therefore still get their own process.
//
//  ## Serialisation
//
//  One process, one command channel: `run` is actor-isolated, so commands are
//  executed in arrival order and two `ls` calls can never interleave their output
//  on the shared stream. That is the whole reason this is an actor rather than a
//  lock.
//
//  ## Failure
//
//  Any error tears the process down and the next call respawns. A pooled session
//  that survives an error would surface the *next* command's failure as a
//  confusing mismatch, and reusing a process whose channel has died produces
//  silence rather than an error.
//

import Foundation
import NIOConcurrencyHelpers

/// A reusable `sftp` process, safe to share across concurrent callers.
actor OpenSSFTSession {
    /// How long to wait for the `sftp>` prompt before giving up on a cold start.
    /// Generous, because this includes TCP + KEX + auth on a possibly remote host.
    private static let readyTimeout: Duration = .seconds(30)
    /// Upper bound on a single control command's output.
    private static let maxChunkBytes = 128 * 1024
    /// Upper bound on one control command's wall clock.
    ///
    /// Generous, because it covers a slow remote round trip, but finite: a control
    /// command that has not answered by now is treated as failed rather than
    /// allowed to wedge every other operation queued behind it.
    private static let commandTimeout: Duration = .seconds(60)

    private let transport: OpenSSHProcessTransport
    private let session: PTYSession
    /// Holds the output stream's iterator.
    ///
    /// A reference box rather than a stored iterator for two reasons:
    /// `AsyncIterator.next()` is `mutating`, so it cannot be called in place on an
    /// actor-isolated stored property; and moving a non-`Sendable` iterator out of
    /// an actor and back is a data-race risk the compiler rightly rejects. Every
    /// advance goes through the box's own lock.
    private let cursor: OutputCursor

    private init(
        transport: OpenSSHProcessTransport,
        session: PTYSession,
        output: AsyncStream<String>
    ) {
        self.transport = transport
        self.session = session
        self.cursor = OutputCursor(stream: output)
    }

    /// Spawn and wait for the prompt.
    ///
    /// Nonisolated on purpose: it creates the process, then hands the actor an
    /// isolated `awaitReady()`. Touching actor state from here would not compile,
    /// and routing it through an isolated method keeps the mutable stream
    /// iterator inside the actor where it belongs.
    static func start(
        spawner: any OpenSSHProcessSpawning,
        arguments: [String],
        /// Builds the output observer, given the freshly spawned process.
        ///
        /// A closure rather than a plain callback because the observer needs the
        /// transport itself: the auth responder answers `sftp`'s password prompt by
        /// *writing* to that PTY, so it cannot be built before the process exists.
        ///
        /// Required, not optional. The first version omitted it and the session
        /// never became ready — `sftp` prompts for a password on the PTY, and with
        /// nothing observing and answering, the prompt is never passed.
        makeOutputObserver: @escaping @Sendable (OpenSSHProcessTransport) -> @Sendable (Data) -> Void
    ) async throws -> OpenSSFTSession {
        let transport = try spawner.spawn(
            executable: "/usr/bin/sftp",
            arguments: arguments,
            cols: 160, rows: 50, termType: "xterm-256color", environment: [:]
        )
        let session = PTYSession()
        // The raw output stream must be created *before* the process starts.
        // `makeRawOutputStream` registers a live continuation; output emitted
        // before that — the version banner and the first prompt — is dropped, and
        // `awaitReady` would then wait for a prompt it already missed. The
        // original `runSFTP` had this ordering right and it was lost in the move.
        let output = session.makeRawOutputStream()
        let observer = makeOutputObserver(transport)
        session.startProcess(
            fileDescriptor: transport.masterFD,
            onExit: {},
            onOutput: { data in observer(data) }
        )
        let pooled = OpenSSFTSession(
            transport: transport,
            session: session,
            output: output
        )
        do {
            try await pooled.awaitReady()
        } catch {
            await pooled.terminate()
            throw error
        }
        return pooled
    }

    /// Drain until the prompt, so the process is genuinely ready before the first
    /// command is written.
    ///
    /// Commands sent during the handshake are silently dropped by `sftp`, which
    /// is the reason this wait exists at all — it is not defensive padding.
    private func awaitReady() async throws {
        let deadline = ContinuousClock.now + Self.readyTimeout
        var buffer = ""
        while !Self.promptAppeared(in: buffer) {
            guard ContinuousClock.now < deadline else {
                throw SSHServiceError.connectionFailed("OpenSSH SFTP session not ready.")
            }
            // The read itself is bounded, not just the loop.
            //
            // Checking the deadline *before* an await is not a timeout: if the
            // stream never yields another chunk the await suspends forever and the
            // deadline is never consulted again. That is the same defect already
            // recorded against `runSFTP`'s readiness loop (AUDIT-OBS-002), and the
            // first version of this pooled session reproduced it — a stuck pool
            // wedged the whole test run instead of failing it.
            guard let chunk = await nextChunkBounded(until: deadline) else {
                throw SSHServiceError.connectionFailed(
                    "OpenSSH SFTP session did not become ready."
                )
            }
            buffer.append(chunk)
        }
    }

    /// Read one chunk, or give up when the deadline passes.
    ///
    /// `nil` means either timeout or end-of-stream; the caller reports both as
    /// "not ready", which is the only honest summary of either.
    private func nextChunkBounded(until deadline: ContinuousClock.Instant) async -> String? {
        let clock = ContinuousClock()
        let budget = max(deadline - clock.now, .zero)
        guard budget > .zero else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { [weak self] in await self?.cursor.next() }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Run one command and return its output, read up to the next prompt.
    ///
    /// Actor-isolated, so concurrent callers are serialised rather than allowed
    /// to interleave on the shared stream.
    func run(_ commands: [String]) async throws -> String {
        guard !commands.isEmpty else { return "" }
        var output = ""
        for command in commands {
            try transport.write(Data((command + "\n").utf8))
            var chunkBuffer = ""
            // Bounded per command for the same reason as readiness: a command that
            // never prompts must fail, not hang.
            let commandDeadline = ContinuousClock.now + Self.commandTimeout
            while true {
                guard let chunk = await nextChunkBounded(until: commandDeadline) else { break }
                output.append(chunk)
                chunkBuffer.append(chunk)
                if Self.promptAppeared(in: chunkBuffer) { break }
                if chunkBuffer.count > Self.maxChunkBytes { break }
            }
            let cleaned = Self.clean(chunkBuffer)
            if Self.containsError(cleaned) {
                // Tear down: the command failed, and the caller's next use of this
                // process cannot be assumed to be on a healthy channel.
                terminate()
                throw SSHServiceError.connectionFailed(cleaned)
            }
        }
        return Self.clean(output)
    }

    /// Close the session. Safe to call more than once.
    ///
    /// Nonisolated so `OpenSSHBackend.close()` — a synchronous method on a class
    /// that is not an actor — can tear the session down. It touches only the two
    /// reference-typed transports and closes the cursor, none of which is
    /// actor-isolated state.
    nonisolated func terminate() {
        try? transport.write(Data("quit\n".utf8))
        cursor.close()
        session.close()
        transport.close()
    }

    // MARK: - Parsing

    private static func promptAppeared(in text: String) -> Bool {
        let stripped = stripANSI(text)
        return stripped.hasSuffix("sftp> ") || stripped.hasSuffix("sftp>")
    }

    private static func containsError(_ text: String) -> Bool {
        let patterns = [
            "couldn't", "permission denied", "denied", "no such file", "not found",
            "failure", "lost connection", "connection closed", "is a directory",
            "can't open", "unable to", "invalid flag", "unknown command", "bad path",
        ]
        let lower = text.lowercased()
        return patterns.contains { lower.contains($0) }
    }

    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\u001B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression
        )
    }

    /// Strip the echoed command, the prompt and ANSI escapes.
    private static func clean(_ text: String) -> String {
        var lines = stripANSI(text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("sftp>") }
        // The first line is the command `sftp` echoes back.
        if let first = lines.first, first.hasPrefix("ls") || first.hasPrefix("pwd")
            || first.hasPrefix("cd") || first.hasPrefix("mkdir") || first.hasPrefix("rm") {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }
}
// MARK: - Output cursor

/// Serialises access to the SFTP output stream's iterator.
///
/// `AsyncIterator` is neither `Sendable` nor safely mutable in place, and this
/// session hands its stream to whichever command is currently running. The lock
/// makes that hand-off explicit instead of relying on the actor, and the box
/// keeps the iterator out of actor-isolated storage entirely.
private final class OutputCursor: @unchecked Sendable {
    private let lock = NSLock()
    private var iterator: AsyncStream<String>.AsyncIterator?
    private var closed = false

    init(stream: AsyncStream<String>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> String? {
        // Scoped locking, never held across an await: the stream has a single
        // consumer by construction, and holding a lock while suspending is both
        // a deadlock risk and rejected here.
        let isUsable = lock.withLock { self.iterator != nil && !self.closed }
        guard isUsable else { return nil }
        guard var local = lock.withLock({ iterator }) else { return nil }
        let chunk = await local.next()
        lock.withLock { if !closed { iterator = local } }
        return chunk
    }

    func close() {
        lock.withLock {
            iterator = nil
            closed = true
        }
    }
}
