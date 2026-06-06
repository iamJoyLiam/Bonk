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
            feedTask?.cancel()
            // Reset batch state
            batchBuffer.withLock { $0 = "" }
            batchFlushScheduled.withLock { $0 = false }

            feedTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(150))
                for await text in stream {
                    guard !Task.isCancelled else { break }
                    let byteCount = text.utf8.count
                    let shouldFlush = batchBuffer.withLock { buf -> Bool in
                        buf += text
                        return buf.utf8.count >= Self.batchThreshold
                    }
                    if shouldFlush {
                        flushBatch()
                    } else {
                        scheduleFlush()
                    }
                    onBytesProcessed?(byteCount)
                }
            }
        }

        func scheduleFlush() {
            let alreadyScheduled = batchFlushScheduled.withLock { val -> Bool in
                if !val { val = true; return false }
                return true
            }
            guard !alreadyScheduled else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(16))
                self?.flushBatch()
            }
        }

        func flushBatch() {
            batchFlushScheduled.withLock { $0 = false }
            let text = batchBuffer.withLock { buf -> String in
                let flushedText = buf
                buf = ""
                return flushedText
            }
            guard !text.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.terminalView?.feed(text: text)
            }
        }
    }

#endif
