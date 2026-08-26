//
//  DisplaySource.swift
//  Bonk
//
//  Abstraction over the display tick. Engine coalesces to one
//  flush per tick, not per byte chunk.
//

import Foundation

/// Produces a tick stream. Engine flushes at most once per tick.
protocol DisplaySource: Sendable {
    var ticks: AsyncStream<Void> { get }
}

#if os(macOS)
import AppKit
import CoreVideo

/// Display-synced tick source. Uses CVDisplayLink on macOS (frame-aligned)
/// and falls back to 16ms Task loop when unavailable (e.g. headless).
final class AppKitDisplaySource: DisplaySource, @unchecked Sendable {
    let ticks: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var displayLink: CVDisplayLink?
    private var fallbackTask: Task<Void, Never>?

    init(preferDisplayLink: Bool = true) {
        var cont: AsyncStream<Void>.Continuation!
        self.ticks = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { c in cont = c }
        self.continuation = cont
        if preferDisplayLink, !setupCVDisplayLink() {
            startFallback()
        }
    }

    deinit {
        if let link = displayLink { CVDisplayLinkStop(link) }
        fallbackTask?.cancel()
        continuation.finish()
    }

    private func setupCVDisplayLink() -> Bool {
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let l = link else { return false }
        self.displayLink = l
        // Bridge self weakly via callback context
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(l, { _, _, _, _, _, ctx in
            guard let ctx else { return kCVReturnSuccess }
            let source = Unmanaged<AppKitDisplaySource>.fromOpaque(ctx).takeUnretainedValue()
            source.continuation.yield(())
            return kCVReturnSuccess
        }, ctx)
        CVDisplayLinkStart(l)
        return true
    }

    private func startFallback() {
        fallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                self?.continuation.yield(())
            }
        }
    }
}
#endif

/// Manual tick source for tests. Caller controls when flush happens.
final class TestDisplaySource: DisplaySource, @unchecked Sendable {
    let ticks: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        var cont: AsyncStream<Void>.Continuation!
        self.ticks = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { c in cont = c }
        self.continuation = cont
    }

    func tick() { continuation.yield(()) }
    func finish() { continuation.finish() }

    deinit { continuation.finish() }
}
