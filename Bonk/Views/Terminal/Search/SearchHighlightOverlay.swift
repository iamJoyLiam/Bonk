//
//  SearchHighlightOverlay.swift
//  Bonk
//
//  Shared search state.
//

#if os(macOS)
    import AppKit

    enum TerminalSearchState {
        @MainActor
        static var isActive: Bool = false
    }
#endif
