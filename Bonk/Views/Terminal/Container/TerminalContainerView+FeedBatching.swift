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
            // Reset batch state
            batchBuffer.withLock { $0 = "" }
            batchFlushScheduled.withLock { $0 = false }

            Log.ui.info("[Feed] Starting new feed task")
            feedTask = Task { [weak self] in
                guard let self else {
                    Log.ui.warning("[Feed] Self deallocated, exiting")
                    return
                }
                // No initial delay — replayed buffer should paint immediately on tab switch
                Log.ui.info("[Feed] Feed task started, waiting for data")
                for await text in stream {
                    guard !Task.isCancelled else {
                        Log.ui.info("[Feed] Feed task cancelled")
                        break
                    }
                    let (shouldFlush, endsCR) = batchBuffer.withLock { buf -> (Bool, Bool) in
                        buf += text
                        let endsCR = buf.utf8.last == 0x0D
                            && buf.utf8.count >= 2
                            && buf.utf8.dropLast().last != 0x0A
                        return (buf.utf8.count >= Self.batchThreshold, endsCR)
                    }
                    if shouldFlush {
                        flushBatch(onBytesProcessed: onBytesProcessed)
                    } else if !endsCR {
                        // Normal path: schedule time-based flush.
                        // When buffer ends with bare CR, skip the flush so the
                        // CR and its replacement text stay in the same batch —
                        // prevents garbled output from programs like Docker
                        // Compose that use \r for in-place line updates.
                        scheduleFlush(onBytesProcessed: onBytesProcessed)
                    }
                }
                Log.ui.info("[Feed] Feed task ended")
            }
        }

        func scheduleFlush(onBytesProcessed: (@Sendable (Int) -> Void)? = nil) {
            let alreadyScheduled = batchFlushScheduled.withLock { val -> Bool in
                if !val { val = true; return false }
                return true
            }
            guard !alreadyScheduled else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(5))
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
