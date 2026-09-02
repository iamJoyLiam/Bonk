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
            onSend(data)
        }

        func sizeChanged(source _: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            // Size sync is now handled by NativeTerminalView.layout()
            // This delegate method is kept for compatibility but no longer drives PTY sync
            _ = newCols
            _ = newRows
        }

        func setTerminalTitle(source _: SwiftTerm.TerminalView, title: String) {
            onTitleChange?(title)
        }

        func hostCurrentDirectoryUpdate(source _: SwiftTerm.TerminalView, directory _: String?) {}
        func scrolled(source terminal: SwiftTerm.TerminalView, position: Double) {
            flashScroller(in: terminal)
        }

        func requestOpenLink(source _: SwiftTerm.TerminalView, link: String, params _: [String: String]) {
            // SwiftTerm detects OSC 8 links and implicit URLs (linkReporting
            // defaults to .implicit); open them in the default browser.
            // Cmd+click activates; plain click only when no selection/drag.
            var components = URLComponents(string: link)
            if components?.scheme == nil {
                components?.scheme = "https"
            }
            guard let scheme = components?.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let url = components?.url
            else { return }
            NSWorkspace.shared.open(url)
        }
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

        // MARK: - Scrollbar Flash

        /// Overlay scrollbar: show on scroll, hide when idle
        // / SwiftTerm  NSScroller NSScrollView ， alpha 。
        private func flashScroller(in terminal: SwiftTerm.TerminalView) {
            // Delegate callbacks arrive on the main thread.
            MainActor.assumeIsolated {
                guard let scroller = terminal.subviews.compactMap({ $0 as? NSScroller }).first else { return }

                // Cancel fade-out
                scroller.layer?.removeAnimation(forKey: "scrollerFadeOut")

                // Show immediately
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    scroller.animator().alphaValue = 1.0
                }

                // Fade out after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    MainActor.assumeIsolated {
                        NSAnimationContext.runAnimationGroup { context in
                            context.duration = 0.4
                            scroller.animator().alphaValue = 0.0
                        }
                    }
                }
            }
        }
    }

#endif
