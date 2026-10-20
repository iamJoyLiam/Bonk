//
//  SFTPService.swift
//  Bonk
//

@preconcurrency import Citadel
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOFoundationCompat
import os.log

/// High-level SFTP operations with OpenSSH and Citadel backends.
@Observable
@MainActor
final class SFTPService {
    var currentPath: String = "/"
    var entries: [SFTPFileEntry] = []
    var isLoading: Bool = false
    var errorMessage: String?
    /// Active transfers.
    ///
    /// ## Computed so every mutation is observable
    ///
    /// The toolbar ring observes `transferTick`, not this array, and that is
    /// deliberate. Progress ticks mutate *elements* — `transfers[idx].fraction`,
    /// `transfers[idx].transferredBytes` — which leave the array property itself
    /// untouched, so an observer reading `transfers` saw the initial `append` and
    /// then nothing: the ring froze at the start of every transfer and the popover
    /// rebuilt itself from a stale snapshot.
    ///
    /// Routing the array through a computed property fixes that structurally
    /// rather than by convention. An in-place subscript write performs
    /// get → modify → set, so the setter — and therefore the tick — runs on every
    /// path: appends, removals, element writes, and writes from outside this type.
    /// Nothing has to remember to announce itself, which is the only way the
    /// invariant survives the next person editing a transfer method.
    var transfers: [SFTPTransfer] {
        get { storedTransfers }
        set {
            storedTransfers = newValue
            yieldTransferTick()
        }
    }

    private var storedTransfers: [SFTPTransfer] = []

    /// Update one transfer in place, by replacement.
    ///
    /// ## Why not `transfers[idx].fraction = x`
    ///
    /// That form mutates an element of a computed property. It is *supposed* to
    /// route through the setter, and with `@Observable` wrapping the storage it
    /// does not reliably: the tick stayed put and the toolbar ring froze. The
    /// element was still updated — so nothing looked wrong in the service, only in
    /// the one place that watches it.
    ///
    /// Copying the element out, mutating the copy and writing it back always
    /// assigns through the setter, on every call, regardless of what the macro
    /// generates. Every production update site goes through here.
    func updateTransfer(_ id: UUID, _ mutate: (inout SFTPTransfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        var copy = transfers[index]
        mutate(&copy)
        transfers[index] = copy
    }

    /// Monotonic counter bumped on every `transfers` mutation.
    ///
    /// One `Int` is a reliable signal even when the change is an element write
    /// rather than a whole-array replacement.
    private(set) var transferTick: Int = 0

    /// One yield per `transfers` mutation, for observers.
    ///
    /// ## Why a stream and not `withObservationTracking`
    ///
    /// The toolbar used to watch `transferTick` with `withObservationTracking`. Its
    /// callback closure is **nonisolated**, while this service is `@MainActor` —
    /// so the observation was registered from a context that does not own the
    /// state. It fired unreliably, which showed up as a toolbar item that froze the
    /// moment a transfer started and never recovered.
    ///
    /// A stream yields *into* the actor, so the observer's continuation resumes on
    /// the main actor with the state already valid. No cross-actor registration and
    /// no one-shot re-arming.
    ///
    /// Built once, on first use, and kept. Building it per subscriber meant the most
    /// recent caller silently replaced the previous one's continuation, and any tick
    /// yielded before a subscriber arrived was discarded — including, for a transfer
    /// that finishes quickly, the tick that says it finished.
    ///
    /// Unbounded buffering is deliberate: a *dropping* stream would lose the final
    /// "finished" signal, which is the one that must never be dropped. The volume is
    /// bounded by coalescing in the consumer, not here.
    /// `@ObservationIgnored` because the channel is plumbing, not observed state —
    /// and because `@Observable` rewrites stored properties into computed ones,
    /// which cannot be `lazy`.
    @ObservationIgnored
    private var storedTransferChannel: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)?

    private var transferChannel: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation) {
        if let storedTransferChannel { return storedTransferChannel }
        let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        storedTransferChannel = channel
        return channel
    }

    /// Ticks from every `transfers` mutation.
    var transferUpdates: AsyncStream<Void> { transferChannel.stream }

    private func yieldTransferTick() {
        transferTick &+= 1
        transferChannel.continuation.yield()
    }

    // Unified seam — one channel for all backends (Citadel/OpenSSH/VNext).
    // Deep SFTPStore will own this; SFTPService currently bridges.
    private var channel: (any SFTPChannel)?
    private var sftpClient: SFTPClient?
    #if os(macOS)
        private var openSSHSFTPClient: OpenSSHSFTPClient?
    #endif
    private var vnextChannel: (any SFTPChannel)?
    /// Backend routing preference (synced from settings; automatic default).
    /// Citadel-first: automatic and citadelExperimental try Citadel, then
    /// fall back to OpenSSH. openSSH forces OpenSSH only (no Citadel).
    var preferredBackend: SFTPBackend = .automatic
    /// The terminal transport. OpenSSH terminals never start on Citadel.
    private var transportIsOpenSSH = false
    /// True once this service's channel is an OpenSSH client.
    private var usingOpenSSH = false
    /// Kept so a Citadel transfer can degrade to OpenSSH without replacing the terminal.
    private var networkService: SSHNetworkService?
    #if os(macOS)
        /// Owns the ControlPath for a transfer-time OpenSSH fallback.
        private var fallbackOpenSSHBackend: OpenSSHBackend?
    #endif
    /// Session RTT snapshot for the planner (Commit-2). Reset on every
    /// fresh connection, probed once after connect, reused by all
    /// transfers in the session. Stays nil when unmeasured or when the
    /// probe fails — never blocks SFTP.
    var sessionRTT = SFTPSessionRTTCache()
    /// Monotonic counter for listDirectory: a stale result (background
    /// refresh finishing after the user navigated) must not overwrite the
    /// newer listing.
    private var listRequestSequence = 0

    /// Claim the next list request id.
    /// Start a list request.
    ///
    /// A foreground request advances `listRequestSequence`, which is what makes
    /// older foreground results drop out. A background refresh deliberately does
    /// **not**: it must never be able to invalidate a navigation the user started,
    /// however late it arrives. See `listDirectory`.
    private func beginListRequest(isBackground: Bool = false) -> Int {
        if isBackground { return listRequestSequence }
        listRequestSequence += 1
        return listRequestSequence
    }

    /// Whether a completed list result is still the one the user should see.
    ///
    /// Foreground: superseded if any later foreground request started.
    /// Background: additionally superseded if the user has navigated away, since a
    /// refresh of a directory nobody is looking at must not yank them back.
    private func isListResultCurrent(_ requestID: Int, isBackground: Bool, path: String) -> Bool {
        guard requestID == listRequestSequence else { return false }
        if isBackground, currentPath != path { return false }
        return true
    }

    init() {}

    /// Open SFTP over the active SSH transport.
    func connect(using sshService: SSHNetworkService) async throws {
        if let channel {
            if entries.isEmpty { try await listDirectory() }
            return
        }
        #if os(macOS)
            if let openSSHSFTPClient, openSSHSFTPClient.isActive {
                // Legacy path still populates unified channel for new callers
                channel = OpenSSHSFTPChannelAdapter(client: openSSHSFTPClient)
                if entries.isEmpty { try await listDirectory() }
                return
            }
        #endif
        if let sftpClient, sftpClient.isActive {
            channel = CitadelSFTPAdapter(
                sftp: sftpClient,
                pooledConfig: await sshService.config,
                pooledStore: sshService.hostKeyStore,
                rttProvider: sessionRTT,
                poolFactory: DefaultSFTPPoolFactory()
            )
            if entries.isEmpty { try await listDirectory() }
            return
        }
        channel = nil
        sftpClient = nil
        sessionRTT.reset()
        #if os(macOS)
            openSSHSFTPClient = nil
        #endif
        vnextChannel = nil

        Log.sftp.info("Opening SFTP session...")
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        #if os(macOS)
            networkService = sshService
            transportIsOpenSSH = await sshService.usesOpenSSHTransport
            // OpenSSH terminal, or an explicit OpenSSH preference: SFTP is OpenSSH.
            // Citadel experimental is the only setting that still starts Citadel
            // beside an OpenSSH terminal.
            let sftpFollowsOpenSSH = preferredBackend == .openSSH
                || (transportIsOpenSSH && preferredBackend != .citadelExperimental)
            if sftpFollowsOpenSSH {
                guard let client = try await sshService.openOpenSSHSFTPClient() else {
                    throw SFTPServiceError.operationFailed("OpenSSH SFTP is unavailable for this connection.")
                }
                do {
                    let path = try await client.realPath()
                    openSSHSFTPClient = client
                    channel = OpenSSHSFTPChannelAdapter(client: client)
                    vnextChannel = channel
                    usingOpenSSH = true
                    currentPath = path
                    Log.sftp.info("OpenSSH SFTP connected, initial path: \(self.currentPath)")
                    try await listDirectory()
                    await refreshSessionRTT()
                    return
                } catch {
                    client.close()
                    openSSHSFTPClient = nil
                    channel = nil
                    vnextChannel = nil
                    throw error
                }
            }
        #endif

        // One decision, one implementation. `SFTPBackendFallback.run` owns the
        // sequence so the tests exercise the function production runs; the gate
        // is not restated here, because a second copy of it is how the original
        // defect existed — an untyped catch that could not tell a rejected host
        // key from a refused connection.
        // A host-key mismatch must not reach the second transport. The two
        // transports keep independent trust state (PersistentHostKeyStore in
        // UserDefaults, versus a known_hosts file ssh(1) writes itself), so
        // retrying does not re-run the check: OpenSSH has never seen this host,
        // `accept-new` accepts the key Citadel just rejected, and the
        // attacker's key is persisted as trusted. A detected MITM would become a
        // silent one.
        //
        // The SSH session path already draws this line — see
        // `SSHFailureClassification.canFallbackToCompatibility`, which excludes
        // `.hostKeyVerification` — and it is honoured here through the same
        // shared predicate rather than a second opinion.
        let openSSHLeg: (@MainActor () async throws -> Void)?
        if preferredBackend == .openSSH {
            openSSHLeg = nil
        } else {
            openSSHLeg = { [self] in try await connectOpenSSHLeg(sshService) }
        }
        try await SFTPBackendFallback.run(
            SFTPBackendLegs(
                citadel: { [self] in try await connectCitadelLeg(sshService) },
                openSSH: openSSHLeg
            )
        )
    }

    /// The Citadel/native leg. Throws whatever the SSH layer threw, after
    /// releasing the client so a failed attempt leaves no half-open channel.
    private func connectCitadelLeg(_ sshService: SSHNetworkService) async throws {
        let client = try await sshService.openSFTPClient()
        do {
            let path = try await client.getRealPath(atPath: ".")
            sftpClient = client
            channel = CitadelSFTPAdapter(
                sftp: client,
                pooledConfig: await sshService.config,
                pooledStore: sshService.hostKeyStore,
                rttProvider: sessionRTT,
                poolFactory: DefaultSFTPPoolFactory()
            )
            vnextChannel = channel
            currentPath = path
            Log.sftp.info("SFTP connected, initial path: \(self.currentPath)")
            try await listDirectory()
            await refreshSessionRTT()
        } catch {
            try? await client.close()
            sftpClient = nil
            channel = nil
            vnextChannel = nil
            throw error
        }
    }

    /// The OpenSSH leg. Runs only when `SFTPBackendFallback` permits it.
    private func connectOpenSSHLeg(_ sshService: SSHNetworkService) async throws {
        guard let fallback = try await sshService.openOpenSSHSFTPClient() else {
            throw SFTPServiceError.operationFailed("OpenSSH SFTP is unavailable for this connection.")
        }
        do {
            let path = try await fallback.realPath()
            openSSHSFTPClient = fallback
            channel = OpenSSHSFTPChannelAdapter(client: fallback)
            vnextChannel = channel
            usingOpenSSH = true
            currentPath = path
            Log.sftp.info("OpenSSH SFTP connected, initial path: \(self.currentPath)")
            try await listDirectory()
            await refreshSessionRTT()
        } catch {
            fallback.close()
            openSSHSFTPClient = nil
            channel = nil
            vnextChannel = nil
            throw error
        }
    }

    /// Commit-2: probe session RTT once per fresh connection for the
    /// planner. Never throws and never blocks SFTP: probe failure leaves
    /// the cache empty (planner nil-fallback branch).
    private func refreshSessionRTT() async {
        guard let channel else { return }
        await sessionRTT.refreshIfNeeded { [channel] in
            var samples: [Double] = []
            for _ in 0..<3 {
                let start = Date()
                guard (try? await channel.realPath()) != nil else { continue }
                samples.append(Date().timeIntervalSince(start) * 1000)
            }
            guard !samples.isEmpty else { return nil }
            return samples.reduce(0, +) / Double(samples.count)
        }
    }

    /// VNext — connect via unified SSHSession (single-connection multiplex, T5)
    func connect(using session: any SSHSession, network: SSHNetworkService? = nil) async throws {
        networkService = network
        #if os(macOS)
            transportIsOpenSSH = session is CompatibilitySSHSession
        #endif
        if let channel {
            if entries.isEmpty { try await listDirectory() }
            return
        }
        if let vnextChannel {
            channel = vnextChannel
            if entries.isEmpty { try await listDirectory() }
            return
        }
        vnextChannel = nil
        channel = nil
        sessionRTT.reset()
        Log.sftp.info("Opening SFTP via VNext session...")
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let character = try await session.openSFTP()
        let path = try await character.realPath()
        vnextChannel = character
        channel = character
        #if os(macOS)
            usingOpenSSH = session is CompatibilitySSHSession
        #endif
        currentPath = path
        Log.sftp.info("VNext SFTP connected, initial path: \(self.currentPath)")
        try await listDirectory()
        await refreshSessionRTT()
    }

    /// List files in the current directory.
    ///
    /// `showLoading: false` marks a **background refresh** — one that must never
    /// cancel user navigation.
    ///
    /// ## Why background refreshes do not advance the sequence
    ///
    /// `listDirectory` used to guard every result against `listRequestSequence`,
    /// and a background refresh advanced that sequence like any other request.
    /// That made this sequence: the user double-clicks a folder, and 600ms after
    /// an unrelated `.shellCommandDidEnd` the auto-refresh starts. The refresh
    /// bumps the sequence, so when the navigation's own result arrives its guard
    /// fails and it returns **without applying anything**. The refresh then
    /// re-lists the directory the user was already in, so the list never changes
    /// and the double-click appears to do nothing — intermittently, depending on
    /// whether a shell command had just finished.
    ///
    /// A background refresh now takes a ticket but does not advance the sequence.
    /// It applies its result only if nothing newer started *and* the user has not
    /// navigated away since. Two foreground requests still supersede each other,
    /// which is what the sequence was actually for.
    func listDirectory(_ path: String? = nil, showLoading: Bool = true) async throws {
        guard let character = channel ?? vnextChannel else {
            Log.sftp.error("listDirectory failed: not connected")
            throw SFTPServiceError.notConnected
        }
        if showLoading { self.isLoading = true }
        self.errorMessage = nil
        defer { if showLoading { self.isLoading = false } }
        let targetPath = path ?? self.currentPath
        let isBackground = !showLoading
        let requestID = self.beginListRequest(isBackground: isBackground)
        var result = try await character.listDirectory(at: targetPath)
        guard self.isListResultCurrent(requestID, isBackground: isBackground, path: targetPath) else {
            if isBackground {
                Log.sftp.debug("[LIST] background refresh for \(targetPath, privacy: .public) superseded; discarded")
            }
            return
        }
        let sorted = await Task.detached(priority: .userInitiated) {
            result.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }.value
        guard self.isListResultCurrent(requestID, isBackground: isBackground, path: targetPath) else {
            if isBackground {
                Log.sftp.debug("[LIST] background refresh for \(targetPath, privacy: .public) superseded while sorting; discarded")
            }
            return
        }
        entries = sorted
        currentPath = targetPath
    }

    /// Navigate to parent directory.
    func goUp() async throws {
        guard currentPath != "/" else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        try await listDirectory(parent.isEmpty ? "/" : parent)
    }

    /// Navigate into a directory.
    func enterDirectory(_ entry: SFTPFileEntry) async throws {
        guard entry.isDirectory else { return }
        try await listDirectory(entry.path)
    }

    /// Create a new directory.
    func createDirectory(name: String) async throws {
        guard let character = channel ?? vnextChannel else { throw SFTPServiceError.notConnected }
        let newPath = pathJoin(currentPath, name)
        try await character.createDirectory(at: newPath)
        try await listDirectory()
    }

    /// Delete a file or directory.
    func delete(_ entry: SFTPFileEntry) async throws {
        guard let character = channel ?? vnextChannel else { throw SFTPServiceError.notConnected }
        try await character.remove(at: entry.path, isDirectory: entry.isDirectory)
        try await listDirectory()
    }

    /// Run a transfer, and on a Citadel failure try the same transfer once on OpenSSH.
    ///
    /// Parallel and the single stream already ran inside the Citadel channel.
    /// This is the last step, and only when the policy allows it. The original
    /// error is what escapes if OpenSSH cannot be opened or itself fails.
    private func transferring(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            let original = error
            guard SFTPDegradation.shouldRetryOnOpenSSH(
                backend: preferredBackend,
                transportIsOpenSSH: transportIsOpenSSH,
                alreadyOpenSSH: usingOpenSSH,
                error: original
            ) else { throw original }
            Log.sftp.warning("[SFTP] Citadel transfer failed, falling back to OpenSSH")
            do {
                guard try await adoptOpenSSH() else { throw original }
                try await body()
            } catch {
                throw original
            }
        }
    }

    /// Point this service at an OpenSSH SFTP client without touching the terminal.
    ///
    /// An OpenSSH terminal already has one. A Citadel terminal gets a separate
    /// OpenSSH process from the same host config. `false` means there is nothing
    /// to switch to; the caller keeps the Citadel error.
    private func adoptOpenSSH() async throws -> Bool {
        #if os(macOS)
            guard let networkService else { return false }
            if let existing = try await networkService.openOpenSSHSFTPClient() {
                installOpenSSH(existing)
                return true
            }
            guard let config = await networkService.config else { return false }
            let backend = try await networkService.makeOpenSSHBackend(config: config)
            let client = backend.makeSFTPClient()
            do {
                _ = try await client.realPath()
            } catch {
                client.close()
                throw error
            }
            fallbackOpenSSHBackend = backend
            installOpenSSH(client)
            return true
        #else
            return false
        #endif
    }

    #if os(macOS)
        private func installOpenSSH(_ client: OpenSSHSFTPClient) {
            openSSHSFTPClient = client
            channel = OpenSSHSFTPChannelAdapter(client: client)
            vnextChannel = channel
            usingOpenSSH = true
        }
    #endif

    /// Download a file to local disk.
    func download(_ entry: SFTPFileEntry, to localURL: URL) async throws {
        // Unified — single channel handles all backends (parallel inside adapter)
        if (channel ?? vnextChannel) != nil {
            guard !entry.isDirectory else { return }
            Log.sftp.debug("[DOWNLOAD] start \(entry.name, privacy: .public) size=\(entry.size)")
            let transferID = UUID()
            transfers.append(SFTPTransfer(id: transferID, filename: entry.name, direction: .download, totalBytes: entry.size, transferredBytes: 0, isComplete: false, error: nil))
            do {
                Log.sftp.debug("[DOWNLOAD] unified character.download call for \(entry.name, privacy: .public)")
                try await transferring {
                    guard let current = self.channel ?? self.vnextChannel else {
                        throw SFTPServiceError.notConnected
                    }
                    try await current.download(entry.path, to: localURL, operationID: transferID, onProgress: { [weak self] progress in
                    let clamped = min(max(progress, 0), 1)
                    guard SFTPProgressThrottler.shared.shouldEmit(id: transferID, progress: clamped) else { return }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // Copy-and-assign through `updateTransfer`. A subscript write
                        // on the `@Observable` array does not bump `transferTick`, so
                        // the toolbar ring stayed idle for the whole transfer.
                        self.updateTransfer(transferID) { transfer in
                            transfer.lastUIUpdate = Date()
                            transfer.fraction = clamped
                            if let total = transfer.totalBytes, total > 0 {
                                let newBytes = UInt64(Double(total) * clamped)
                                if newBytes >= transfer.transferredBytes || clamped >= 1.0 {
                                    transfer.transferredBytes = newBytes
                                }
                            } else if let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path),
                                      let size = attrs[.size] as? UInt64,
                                      size > transfer.transferredBytes || clamped >= 1.0 {
                                transfer.transferredBytes = size
                            }
                        }
                    }
                })
                }
                if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                    updateTransfer(transferID) { t in t.fraction = 1.0 }
                    // Unknown size: entry.size==0, use actual file size on disk
                    if let total = transfers[idx].totalBytes, total > 0 {
                        updateTransfer(transferID) { t in t.transferredBytes = entry.size }
                    } else if let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path),
                              let size = attrs[.size] as? UInt64 {
                        updateTransfer(transferID) { t in t.transferredBytes = size }
                    }
                    updateTransfer(transferID) { t in t.isComplete = true }
                }
                SFTPProgressThrottler.shared.remove(id: transferID)
                scheduleTransferRemoval(transferID, after: Self.successDismissDelay)
            } catch {
                markTransferError(transferID, error: error)
                scheduleTransferRemoval(transferID, after: 5)
                throw error
            }
            return
        }
        throw SFTPServiceError.notConnected
    }

    /// Download file chunks with progress updates.
    /// Reads are pipelined (multiple in flight) so throughput isn'text limited to one
    /// round trip per chunk, then reassembled in order locally.
    /// P2 auto sharding
    private func downloadChunks(
        file: SFTPFile, entry: SFTPFileEntry, localURL: URL,
        transferID: UUID
    ) async throws {
        // Sendable wrapper for the off-MainActor network reads below.
        let remoteFile = SendableSFTPFile(file)

        // P2 parallel download —
        if entry.size > 0, SFTPParallelStrategy.shouldUseParallel(totalBytes: entry.size) {
            Log.sftp.info("[P2] SFTPService downloadChunks parallel total=\(entry.size)")
            do {
                try await SFTPParallelTransferEngine.parallelDownload(
                    remoteFile: remoteFile,
                    localURL: localURL,
                    totalBytes: entry.size,
                    isCancelled: { [weak self] in
                        if Task.isCancelled { return true }
                        guard let self else { return false }
                        return await MainActor.run {
                            self.transfers.first(where: { $0.id == transferID })?.isCancelled ?? false
                        }
                    },
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            guard let self else { return }
                            let clamped = min(max(progress, 0), 1)
                            if let idx = self.transfers.firstIndex(where: { $0.id == transferID }) {
                                self.updateTransfer(transferID) { t in t.transferredBytes = UInt64(Double(entry.size) * clamped) }
                            }
                        }
                    }
                )
                if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                    updateTransfer(transferID) { t in t.transferredBytes = entry.size }
                }
                return
            } catch is CancellationError {
                throw SFTPServiceError.transferCancelled
            } catch let err as SFTPServiceError where err == .transferCancelled {
                throw err
            } catch {
                Log.sftp.warning("[P2] SFTPService parallelDownload failed, fallback: \(String(describing: error))")
                try? FileManager.default.removeItem(at: localURL)
            }
        }

        let chunkSize: UInt32 = UInt32(SFTPParallelStrategy.chunkSize(for: entry.size))
        let pipelineDepth: Int = SFTPParallelStrategy.pipelinePerShard(shards: 1, totalBytes: entry.size)
        var nextReadOffset: UInt64 = 0
        var nextWriteOffset: UInt64 = 0
        var pending: [UInt64: Data] = [:]
        var readDone = false
        var inFlight = 0
        var updateCounter = 0

        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: localURL)
        defer { try? handle.close() }

        // Don'text rely on entry.size for loop control - it may be inaccurate
        // for some file types or SFTP servers. Read until EOF.
        try await withThrowingTaskGroup(of: (UInt64, Data).self) { group in
            while !readDone || inFlight > 0 {
                // Honor user cancellation (same pattern as writeChunks).
                let isCancelled = transfers.first(where: { $0.id == transferID })?.isCancelled ?? false
                if isCancelled { throw SFTPServiceError.transferCancelled }

                // Top up the read pipeline
                while !readDone && inFlight < pipelineDepth {
                    let readOffset = nextReadOffset
                    nextReadOffset += UInt64(chunkSize)
                    inFlight += 1
                    group.addTask {
                        // Network read runs off the MainActor (see SFTPTransferEngine).
                        try await SFTPTransferEngine.readChunk(
                            remoteFile, offset: readOffset, length: chunkSize
                        )
                    }
                }

                guard let (readOffset, data) = try await group.next() else { break }
                inFlight -= 1
                if data.isEmpty {
                    // Only empty at genuine EOF; for known size, check offset
                    if entry.size == 0 || readOffset >= entry.size - UInt64(chunkSize) { readDone = true }
                    continue
                }
                if data.count < Int(chunkSize), entry.size > 0, readOffset + UInt64(data.count) < entry.size {
                    let gapStart = readOffset + UInt64(data.count)
                    let gapLen = UInt32(min(UInt64(chunkSize) - UInt64(data.count), entry.size - gapStart))
                    let gapOff = gapStart
                    inFlight += 1
                    group.addTask {
                        try await SFTPTransferEngine.readChunk(remoteFile, offset: gapOff, length: gapLen)
                    }
                } else if data.isEmpty || data.count < Int(chunkSize) {
                    // Unknown size: short means EOF
                    if entry.size == 0 { readDone = true }
                }
                pending[readOffset] = data
                if entry.size > 0, readOffset + UInt64(data.count) >= entry.size { readDone = true }

                // Write completed chunks back in order — off MainActor via detached
                while let bytes = pending.removeValue(forKey: nextWriteOffset) {
                    let bytesToWrite = bytes
                    try await Task.detached(priority: .userInitiated) {
                        try handle.write(contentsOf: bytesToWrite)
                    }.value
                    nextWriteOffset += UInt64(bytesToWrite.count)
                    updateCounter += 1
                    if updateCounter % 10 == 0 {
                        if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                            updateTransfer(transferID) { t in t.transferredBytes = nextWriteOffset }
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        // Final progress update
        if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
            updateTransfer(transferID) { t in t.transferredBytes = nextWriteOffset }
        }
    }

    /// Mark a transfer as complete.
    private func markTransferComplete(_ transferID: UUID) {
        if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
            updateTransfer(transferID) { t in t.isComplete = true }
        }
    }

    /// Mark a transfer as failed.
    private func markTransferError(_ transferID: UUID, error: Error) {
        if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
            updateTransfer(transferID) { t in t.error = error.localizedDescription }
        }
    }

    /// How long a finished transfer stays visible as a checkmark before the
    /// ring and the browser return to their idle state.
    static let successDismissDelay: TimeInterval = 3

    /// Schedule automatic removal of a transfer after a delay.
    private func scheduleTransferRemoval(_ transferID: UUID, after seconds: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.transfers.removeAll { $0.id == transferID }
        }
    }

    /// Cancel a specific transfer.
    func cancelTransfer(_ transferID: UUID) {
        if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
            updateTransfer(transferID) { t in t.isCancelled = true }
            // Removal was only ever scheduled on the success and error paths, so a
            // cancelled transfer stayed in the list forever at whatever fraction it
            // had reached — most visibly as a row stuck at 100% that never went
            // away. Cancellation is an outcome and gets the same treatment.
            scheduleTransferRemoval(transferID, after: Self.successDismissDelay)
        }
        #if os(macOS)
            openSSHSFTPClient?.cancel(operationID: transferID)
        #endif
    }

    /// Remove a specific transfer from the list.
    func removeTransfer(_ transferID: UUID) {
        transfers.removeAll { $0.id == transferID }
    }

    /// Upload a local file to the remote path. Returns an AsyncStream of progress (0.0 - 1.0).
    func upload(_ localURL: URL, to remotePath: String? = nil) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    try await performUpload(localURL, to: remotePath, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Internal upload implementation.
    private func performUpload(
        _ localURL: URL,
        to remotePath: String?,
        continuation: AsyncThrowingStream<Double, Error>.Continuation
    ) async throws {
        // Unified — single channel seam
        if (channel ?? vnextChannel) != nil {
            let targetPath = remotePath ?? pathJoin(currentPath, localURL.lastPathComponent)
            let filename = localURL.lastPathComponent
            let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
            let total = (attrs?[.size] as? UInt64) ?? 0
            let transferID = UUID()
            transfers.append(SFTPTransfer(id: transferID, filename: filename, direction: .upload, totalBytes: total, transferredBytes: 0, isComplete: false, error: nil))
            do {
                try await transferring {
                    guard let current = self.channel ?? self.vnextChannel else {
                        throw SFTPServiceError.notConnected
                    }
                    try await current.upload(localURL, to: targetPath, operationID: transferID, onProgress: { [weak self] progress in
                    let clamped = min(max(progress, 0), 1)
                    guard SFTPProgressThrottler.shared.shouldEmit(id: transferID, progress: clamped) else { return }
                    Task { @MainActor in
                        guard let self else { return }
                        self.updateTransfer(transferID) { text in
                            text.lastUIUpdate = Date()
                            text.fraction = clamped
                            if let totalUnwrapped = text.totalBytes, totalUnwrapped > 0 {
                                text.transferredBytes = UInt64(Double(totalUnwrapped) * clamped)
                            }
                        }
                        continuation.yield(clamped)
                    }
                })
                }
                if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                    updateTransfer(transferID) { t in t.fraction = 1.0 }
                    updateTransfer(transferID) { t in t.transferredBytes = total }
                    updateTransfer(transferID) { t in t.isComplete = true }
                }
                SFTPProgressThrottler.shared.remove(id: transferID)
                continuation.yield(1.0)
                scheduleTransferRemoval(transferID, after: Self.successDismissDelay)
            } catch {
                markTransferError(transferID, error: error)
                scheduleTransferRemoval(transferID, after: 5)
                throw error
            }
            try? await listDirectory(showLoading: false)
            return
        }
        throw SFTPServiceError.notConnected
    }

    // Legacy OpenSSH direct upload/download removed — all paths go via SFTPChannel adapters (single seam).

    /// Write file chunks with pipelined concurrent writes.
    /// File IO is off MainActor via SFTPTransferActor (DispatchIO), pipeline 1024×32KB=32MB.
    // / P2: >500MB 4/8 shards，。
    private func writeChunks(
        localURL: URL,
        file: SFTPFile,
        totalBytes: UInt64,
        transferID: UUID,
        continuation: AsyncThrowingStream<Double, Error>.Continuation
    ) async throws {
        let remoteFile = SendableSFTPFile(file)

        // P2 parallel path —  Citadel Native ，OpenSSH  performUpload
        if SFTPParallelStrategy.shouldUseParallel(totalBytes: totalBytes) {
            Log.sftp.info("[P2] SFTPService writeChunks parallel total=\(totalBytes)")
            do {
                try await SFTPParallelTransferEngine.parallelUpload(
                    localURL: localURL,
                    remoteFile: remoteFile,
                    totalBytes: totalBytes,
                    isCancelled: { [weak self] in
                        if Task.isCancelled { return true }
                        guard let self else { return false }
                        // Hop  MainActor
                        return await MainActor.run {
                            self.transfers.first(where: { $0.id == transferID })?.isCancelled ?? false
                        }
                    },
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            guard let self else { return }
                            let clamped = min(max(progress, 0), 1)
                            if let idx = self.transfers.firstIndex(where: { $0.id == transferID }) {
                                self.updateTransfer(transferID) { t in t.transferredBytes = UInt64(Double(totalBytes) * clamped) }
                            }
                            continuation.yield(clamped)
                        }
                    }
                )
                // Cancel check
                if transfers.first(where: { $0.id == transferID })?.isCancelled == true {
                    throw SFTPServiceError.transferCancelled
                }
                return
            } catch is CancellationError {
                throw SFTPServiceError.transferCancelled
            } catch let err as SFTPServiceError where err == .transferCancelled {
                throw err
            } catch {
                Log.sftp.warning("[P2] SFTPService parallelUpload failed, fallback to single stream: \(String(describing: error))")
                // fallthrough to single stream
            }
        }

        let chunkSize = SFTPParallelStrategy.chunkSize(for: totalBytes)
        let pipelineDepth: Int = SFTPParallelStrategy.pipelinePerShard(shards: 1, totalBytes: totalBytes)
        let reader = try SFTPTransferActor(url: localURL)
        var offset: UInt64 = 0
        var completedBytes: UInt64 = 0
        var pending = 0
        var updateCounter = 0
        var lastReportedProgress: Double = -1

        do {
            try await withThrowingTaskGroup(of: Int.self) { group in
                while true {
                    let isCancelled = transfers.first(where: { $0.id == transferID })?.isCancelled ?? false
                    if isCancelled { throw SFTPServiceError.transferCancelled }

                    // Top up the write pipeline — file read off MainActor via actor
                    while pending < pipelineDepth {
                        let chunkData = try await reader.readChunk(offset: offset, length: chunkSize)
                        guard !chunkData.isEmpty else { break }
                        let chunkOffset = offset
                        offset += UInt64(chunkData.count)
                        pending += 1
                        group.addTask {
                            try await SFTPTransferEngine.writeChunk(
                                remoteFile, data: chunkData, at: chunkOffset
                            )
                        }
                    }

                    if pending == 0 { break }
                    // Wait for the oldest write to complete
                    guard let written = try await group.next() else { break }
                    pending -= 1
                    completedBytes += UInt64(written)
                    updateCounter += 1

                    if updateCounter % 10 == 0 || completedBytes == totalBytes {
                        if let idx = transfers.firstIndex(where: { $0.id == transferID }) {
                            updateTransfer(transferID) { t in t.transferredBytes = completedBytes }
                        }
                        let progress = totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 1.0
                        if progress - lastReportedProgress >= 0.01 || completedBytes == totalBytes {
                            lastReportedProgress = progress
                            continuation.yield(progress)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
        // Close reader synchronously after all chunks are written
        await reader.close()
    }

    /// Check if a file exists at the given absolute path.
    /// Returns nil when the check itself fails (e.g. network error).
    func fileExists(at path: String) async -> Bool? {
        guard let character = channel ?? vnextChannel else { return nil }
        return await character.fileExists(at: path)
    }

    /// Refresh the current path from the remote server.
    func refreshCurrentPath() async {
        guard let character = channel ?? vnextChannel else { return }
        do { currentPath = try await character.realPath() } catch {
            Log.sftp.warning("Failed to refresh current path: \(error.localizedDescription)")
        }
    }

    /// Close the SFTP session.
    func disconnect() async {
        if let character = channel { await character.close() }
        if let ch2 = vnextChannel { await ch2.close() }
        channel = nil
        vnextChannel = nil
        #if os(macOS)
            openSSHSFTPClient?.close()
            openSSHSFTPClient = nil
        #endif
        try? await sftpClient?.close()
        sftpClient = nil
        entries = []
        for transfer in transfers where !transfer.isComplete {
            updateTransfer(transfer.id) { t in t.isCancelled = true }
        }
    }

    private func pathJoin(_ base: String, _ component: String) -> String {
        URL(fileURLWithPath: base).appendingPathComponent(component).path
    }
}

enum SFTPServiceError: LocalizedError, Equatable {
    case notConnected
    case transferCancelled
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "SFTP session not connected."
        case .transferCancelled: "Transfer cancelled."
        case let .operationFailed(message): message
        }
    }
}

// MARK: - Transfer Engine (off MainActor)

/// Wraps Citadel's SFTPFile so chunk I/O can run outside the MainActor.
/// SFTPFile serializes requests internally via channel request IDs, so
/// concurrent reads/writes are safe; the wrapper only satisfies Swift 6
/// Sendable checks.
final class SendableSFTPFile: @unchecked Sendable {
    let file: SFTPFile
    init(_ file: SFTPFile) { self.file = file }
}

/// Anything the closer can release. Abstracted so the terminal-state
/// ordering (track after close) is testable without a live SFTP channel;
/// production code always uses `SFTPFile`. The type is not required to be
/// `Sendable` itself — the closer only ever moves handles inside its lock.
protocol RemoteClosable {
    func closeRemote() async throws
}

struct SFTPFileHandle: RemoteClosable {
    let file: SFTPFile
    func closeRemote() async throws { try await file.close() }
}

/// Releases remote file handles exactly once, on every exit path of a
/// transfer (success, shard failure, user cancellation).
///
/// A close loop placed after the shard task group only runs when the group
/// succeeds, so any thrown shard leaked its remote fds — under concurrent
/// transfers that exhausts the fd table. `defer { Task { close } }` is not a
/// fix: it also leaves fds open until the spawned task runs.
///
/// Ownership is *closed*, not merely emptied. `closeRemaining()` transitions
/// the closer to a terminal state, and `track(_:)` consults it under the same
/// lock:
///
/// - open  → the handle joins the pending set and is closed on release;
/// - closed → the handle is closed immediately by the tracking call.
///
/// That ordering guarantee is what makes a handle un-ownable impossible. It
/// matters because the failure paths call `closeRemaining()` exactly once,
/// while a shard's `openFile` may still be in flight: an in-flight open that
/// completes afterwards is closed by its own `track` call instead of being
/// stranded with no owner. Emptying the set without a terminal state would
/// leak exactly that handle.
struct RemoteHandleCloser<H: RemoteClosable>: @unchecked Sendable {
    private enum State {
        case open([H])
        case closed
    }

    private let lock = NIOLockedValueBox<State>(.open([]))

    /// Start empty and `track(_:)` handles as they are opened, so a failure
    /// *during* the open loop still releases what was already opened.
    init() {}

    /// Register a handle. If the closer is already closed the handle is closed
    /// before this call returns, so no handle is ever left without an owner.
    func track(_ handle: H) async {
        let closeNow: Bool = lock.withLockedValue { state in
            switch state {
            case .open(var pending):
                pending.append(handle)
                state = .open(pending)
                return false
            case .closed:
                return true
            }
        }
        if closeNow {
            try? await handle.closeRemote()
        }
    }

    func track(contentsOf handles: [H]) async {
        for handle in handles { await track(handle) }
    }

    /// Close every tracked handle and move the closer to its terminal state.
    /// Idempotent: a second call finds no pending handles and does nothing, so
    /// the success path followed by the failure path cannot double-close.
    func closeRemaining() async {
        let pending: [H] = lock.withLockedValue { state in
            defer { state = .closed }
            if case let .open(handles) = state { return handles }
            return []
        }
        for handle in pending {
            try? await handle.closeRemote()
        }
    }
}

typealias SFTPHandleCloser = RemoteHandleCloser<SFTPFileHandle>

extension RemoteHandleCloser where H == SFTPFileHandle {
    func track(_ file: SendableSFTPFile) async { await track(SFTPFileHandle(file: file.file)) }
}

/// SFTP chunk I/O executed OUTSIDE the MainActor. Network round trips are
/// the transfer bottleneck; running 16 in-flight requests on the main thread
/// froze the UI during large transfers. Local disk I/O stays on the main
/// thread — sequential 32KB writes are orders of magnitude faster than the
/// network and never become the bottleneck.
enum SFTPTransferEngine {
    nonisolated static func readChunk(
        _ file: SendableSFTPFile,
        offset: UInt64,
        length: UInt32
    ) async throws -> (UInt64, Data) {
        let data = try await file.file.read(from: offset, length: length)
        return (offset, Data(buffer: data))
    }

    nonisolated static func writeChunk(
        _ file: SendableSFTPFile,
        data: Data,
        at offset: UInt64
    ) async throws -> Int {
        // Zero-copy: avoid Data→Array→ByteBuffer double copy via direct ByteBufferAllocator
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        data.withUnsafeBytes { ptr in
            buffer.writeBytes(ptr)
        }
        try await file.file.write(buffer, at: offset)
        return data.count
    }

    nonisolated static func writeBuffer(
        _ file: SendableSFTPFile,
        buffer: ByteBuffer,
        at offset: UInt64
    ) async throws -> Int {
        // True zero-copy: buffer already from pread, no Data intermediate
        var buf = buffer
        let count = buf.readableBytes
        try await file.file.write(buf, at: offset)
        return count
    }
}
