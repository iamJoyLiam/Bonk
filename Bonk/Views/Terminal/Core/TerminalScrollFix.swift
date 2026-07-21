//
//  TerminalScrollFix.swift
//  Bonk
//
//  ALTBUF-aware scroll wheel handler for vim/less/tmux.
//  SwiftTerm hard-disables scrolling in ALTBUF mode (issue #583),
//  so we must intercept and send arrow keys as fallback.
//
//  Decision tree:
//  - Normal screen → return event (native scroll)
//  - ALTBUF + mouse reporting → send SGR escape (vim with mouse)
//  - ALTBUF + no mouse reporting → send arrow keys (vim without mouse)
//

#if os(macOS)
    import AppKit
    import os.log
    import SwiftTerm

    enum TerminalScrollFix {
        private static let lock = NSLock()
        private nonisolated(unsafe) static var installed = false
        private nonisolated(unsafe) static var monitor: Any?
        private nonisolated(unsafe) static var terminalMap: [ObjectIdentifier: Terminal] = [:]
        private nonisolated(unsafe) static var allowMouseMap: [ObjectIdentifier: () -> Bool] = [:]
        nonisolated(unsafe) static var lastArrowTime: TimeInterval = 0

        static func register(_ view: TerminalView) {
            let id = ObjectIdentifier(view)
            lock.lock()
            terminalMap[id] = view.terminal
            allowMouseMap[id] = { [weak view] in view?.allowMouseReporting ?? false }
            lock.unlock()
        }

        static func unregister(_ view: TerminalView) {
            let id = ObjectIdentifier(view)
            lock.lock()
            terminalMap.removeValue(forKey: id)
            allowMouseMap.removeValue(forKey: id)
            lock.unlock()
        }

        static func install() {
            lock.lock()
            guard !installed else { lock.unlock(); return }
            installed = true
            lock.unlock()

            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                guard let window = event.window else { return event }
                let locationInWindow = event.locationInWindow
                guard let targetView = window.contentView?.hitTest(locationInWindow) as? NSView else {
                    return event
                }

                let id = ObjectIdentifier(targetView)

                lock.lock()
                let terminal = terminalMap[id]
                let mouseAllowed = allowMouseMap[id]?() ?? false
                lock.unlock()

                guard let terminal else { return event }

                let locationInView = targetView.convert(locationInWindow, from: nil)
                guard targetView.bounds.contains(locationInView) else { return event }

                let deltaY = event.deltaY
                guard deltaY != 0 else { return event }

                let isAlternate = terminal.isCurrentBufferAlternate

                // Normal screen → native scroll (SwiftTerm handles this fine)
                guard isAlternate else { return event }

                // ALTBUF mode → must handle scrolling ourselves (SwiftTerm bug #583)
                let mouseMode = terminal.mouseMode

                if mouseAllowed, mouseMode != .off {
                    // ALTBUF + mouse reporting → SGR escape sequences (vim with mouse=a)
                    let cols = terminal.cols
                    let rows = terminal.rows
                    guard cols > 0, rows > 0 else { return event }

                    let cellWidth = targetView.bounds.width / CGFloat(cols)
                    let cellHeight = targetView.bounds.height / CGFloat(rows)
                    let col = max(0, min(Int(locationInView.x / cellWidth), cols - 1))
                    let row = max(0, min(Int((targetView.bounds.height - locationInView.y) / cellHeight), rows - 1))

                    let buttonFlags: Int = deltaY > 0 ? 64 : 65
                    terminal.sendEvent(buttonFlags: buttonFlags, x: col, y: row)
                    terminal.sendEvent(buttonFlags: buttonFlags + 3, x: col, y: row)
                    return nil
                }

                // ALTBUF + no mouse reporting → arrow keys (vim without mouse)
                // Rate limit: max 1 arrow per 30ms for balanced scrolling
                let now = Date.timeIntervalSinceReferenceDate
                guard now - Self.lastArrowTime > 0.03 else { return nil }
                Self.lastArrowTime = now

                // Send exactly 1 arrow key
                let arrowSequence: String = if deltaY > 0 {
                    terminal.applicationCursor ? "\u{1B}OA" : "\u{1B}[A"
                } else {
                    terminal.applicationCursor ? "\u{1B}OB" : "\u{1B}[B"
                }

                terminal.sendResponse(arrowSequence)
                return nil
            }

            Log.ui.info("TerminalScrollFix installed (ALTBUF-aware)")
        }

        static func uninstall() {
            lock.lock()
            defer { lock.unlock() }
            guard installed else { return }
            if let eventMonitor = monitor {
                NSEvent.removeMonitor(eventMonitor)
                monitor = nil
            }
            installed = false
            terminalMap.removeAll()
            allowMouseMap.removeAll()
        }
    }
#endif
