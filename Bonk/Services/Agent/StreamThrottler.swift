import Combine
import Foundation

/// Buffers streaming text and throttles UI updates.
/// Prevents SwiftData from being written on every token.
/// Only persists to SwiftData when the stream ends.
actor StreamThrottler {
    private var buffer = ""
    private let subject = PassthroughSubject<String, Never>()
    private let throttleMs: Int

    init(throttleMs: Int = 100) {
        self.throttleMs = throttleMs
    }

    /// Append a streaming delta to the buffer.
    func append(_ delta: String) {
        buffer += delta
        subject.send(buffer)
    }

    /// Get the current full buffer content.
    func getContent() -> String {
        buffer
    }

    /// Reset the buffer for a new conversation.
    func reset() {
        buffer = ""
    }

    /// A Combine publisher that emits throttled updates.
    /// Use on MainActor to update UI at a stable frame rate.
    func throttledPublisher() -> AnyPublisher<String, Never> {
        subject
            .throttle(for: .milliseconds(throttleMs), scheduler: DispatchQueue.main, latest: true)
            .eraseToAnyPublisher()
    }
}
