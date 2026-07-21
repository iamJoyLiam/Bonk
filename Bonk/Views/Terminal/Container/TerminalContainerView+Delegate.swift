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

        func sizeChanged(source terminal: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            // Block invalid zero-value sizes
            guard newCols > 0 && newRows > 0 else { return }

            // Filter duplicate dimensions
            guard newCols != lastSyncedCols || newRows != lastSyncedRows else { return }

            forceSyncPTY(view: terminal, onResize: onResize)
        }

        func setTerminalTitle(source _: SwiftTerm.TerminalView, title: String) {
            onTitleChange?(title)
        }

        func hostCurrentDirectoryUpdate(source _: SwiftTerm.TerminalView, directory _: String?) {}
        func scrolled(source terminal: SwiftTerm.TerminalView, position _: Double) {
            flashScroller(in: terminal)
        }
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

        // MARK: - Scrollbar Flash

        /// 模拟 NSScrollView 的 overlay 滚动条行为：滚动时显示，静止时隐藏。
        /// SwiftTerm 使用独立 NSScroller（不在 NSScrollView 中），需要手动驱动 alpha 动画。
        private func flashScroller(in terminal: SwiftTerm.TerminalView) {
            guard let scroller = terminal.subviews.compactMap({ $0 as? NSScroller }).first else { return }

            // 取消之前的 fade-out 计划
            scroller.layer?.removeAnimation(forKey: "scrollerFadeOut")

            // 立即显示
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                scroller.animator().alphaValue = 1.0
            }

            // 延迟后淡出
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.4
                    scroller.animator().alphaValue = 0.0
                }
            }
        }
    }

#endif
