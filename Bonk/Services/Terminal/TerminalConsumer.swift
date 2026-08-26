//
//  TerminalConsumer.swift
//  Bonk
//
//  Seam between Engine and view. View is a consumer, Engine is the source.
//  Keeps AppKit out of Engine and makes headless testing a second adapter.
//

import Foundation

/// Receives coalesced terminal text on the MainActor (display work).
@MainActor
protocol TerminalConsumer: AnyObject {
    func receive(_ text: String)
    /// Optional backpressure signal: bytes consumed after rendering.
    func didConsume(bytes: Int)
}

extension TerminalConsumer {
    func didConsume(bytes: Int) {}
}
