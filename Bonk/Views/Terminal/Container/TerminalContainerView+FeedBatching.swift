//
//  TerminalContainerView+FeedBatching.swift
//  Bonk
//
//  Batch feed throttling for terminal output — reduces MainActor.run calls under heavy output.
//

import os
import SwiftTerm

#if os(macOS)
    import AppKit

    extension ContainerTerminalCoordinator {
        func startFeeding(from stream: AsyncStream<String>, onBytesProcessed: (@Sendable (Int) -> Void)? = nil) {
            // Cancel existing feed task before creating new one
            if let existingTask = feedTask {
                Log.ui.info("[Feed] Cancelling existing feed task")
                existingTask.cancel()
            }
            // Legacy batch state cleared (kept for backward compat, now unused)
            batchBuffer.withLock { $0 = "" }
            batchFlushScheduled.withLock { $0 = false }

            // Engine path — single coalescer per display tick, single watermark
            Log.ui.info("[Feed] Starting new feed task (Engine)")

            feedTask = Task { [weak self] in
                guard let self else {
                    Log.ui.warning("[Feed] Self deallocated, exiting")
                    return
                }
                // Clean previous subscription if any
                let oldID: UUID? = await MainActor.run { self.engineConsumerID }
                if let old = oldID {
                    await MainActor.run {
                        self.getOrCreateEngine().unsubscribe(old)
                        if self.engineConsumerID == old {
                            self.engineConsumerID = nil
                            self.engineConsumer = nil
                        }
                    }
                }
                let newID = UUID()
                await MainActor.run { self.engineConsumerID = newID }
                // Subscribe view to engine (MainActor) — hold strong ref so weak Engine entry stays alive
                let engine = await MainActor.run { self.getOrCreateEngine() }
                await MainActor.run {
                    guard let view = self.terminalView else { return }
                    let consumer = AppKitTerminalConsumer(terminalView: view, host: self.hostItem, onBytesProcessed: onBytesProcessed)
                    self.engineConsumer = consumer
                    engine.subscribe(newID, consumer: consumer)
                }
                Log.ui.info("[Feed] Feed task started (Engine), waiting for data")
                for await text in stream {
                    guard !Task.isCancelled else {
                        Log.ui.info("[Feed] Feed task cancelled")
                        break
                    }
                    await MainActor.run { engine.push(text) }
                }
                await MainActor.run {
                    engine.unsubscribe(newID)
                    if self.engineConsumerID == newID {
                        self.engineConsumerID = nil
                        self.engineConsumer = nil
                    }
                }
                Log.ui.info("[Feed] Feed task ended (Engine)")
            }
        }

        func scheduleFlush(onBytesProcessed: (@Sendable (Int) -> Void)? = nil) {
            let alreadyScheduled = batchFlushScheduled.withLock { val -> Bool in
                if !val { val = true; return false }
                return true
            }
            guard !alreadyScheduled else { return }
            Task { [weak self] in
                // Coalesce to one display frame (60 fps ≈ 16 ms) instead of 5 ms.
                // 200 MainActor hops/s → ~60 hops/s, 3× fewer VT parses under flood,
                // while interactive echo still feels instant (< 1 frame delay).
                try? await Task.sleep(for: .milliseconds(16))
                self?.flushBatch(onBytesProcessed: onBytesProcessed)
            }
        }

        func flushBatch(onBytesProcessed: (@Sendable (Int) -> Void)? = nil) {
            batchFlushScheduled.withLock { $0 = false }
            let (text, byteCount) = batchBuffer.withLock { buf -> (String, Int) in
                let flushedText = buf
                let count = flushedText.utf8.count
                buf = ""
                return (flushedText, count)
            }
            guard !text.isEmpty else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.terminalView?.feed(text: text)
                // Signal backpressure AFTER terminal actually processes the text
                onBytesProcessed?(byteCount)
            }
        }
    }

#endif
