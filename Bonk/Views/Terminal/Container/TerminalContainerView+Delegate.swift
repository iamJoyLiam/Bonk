//
//  TerminalContainerView+Delegate.swift
//  Bonk
//
//  SwiftTerm.TerminalViewDelegate conformance for ContainerTerminalCoordinator.
//

import SwiftTerm

#if os(macOS)
    import AppKit

    extension ContainerTerminalCoordinator {
        func send(source _: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            // Log to verify delegate is called
            NSLog("[DELEGATE] send called with \(data.count) bytes")
            onSend(data)
        }

        func sizeChanged(source _: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            onResize?(newCols, newRows)
        }

        func setTerminalTitle(source _: SwiftTerm.TerminalView, title: String) {
            onTitleChange?(title)
        }

        func hostCurrentDirectoryUpdate(source _: SwiftTerm.TerminalView, directory _: String?) {}
        func scrolled(source _: SwiftTerm.TerminalView, position _: Double) {}
        func requestOpenLink(source _: SwiftTerm.TerminalView, link _: String, params _: [String: String]) {}
        func bell(source _: SwiftTerm.TerminalView) {}
        func clipboardCopy(source _: SwiftTerm.TerminalView, content: Data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(content, forType: .string)
        }

        func clipboardRead(source _: SwiftTerm.TerminalView) -> Data? {
            nil
        }

        func iTermContent(source _: SwiftTerm.TerminalView, content _: ArraySlice<UInt8>) {}
        func rangeChanged(source _: SwiftTerm.TerminalView, startY _: Int, endY _: Int) {}
    }

#endif
