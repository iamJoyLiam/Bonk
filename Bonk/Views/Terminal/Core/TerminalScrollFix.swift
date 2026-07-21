//
//  TerminalScrollFix.swift
//  Bonk
//
//  ALTBUF-aware scroll wheel handler for vim/less/tmux.
//
//  Decision tree:
//  - Normal screen + no mouse reporting  → local scroll (default)
//  - Normal screen + mouse reporting     → send SGR escape
//  - ALTBUF + mouse reporting            → send SGR escape
//  - ALTBUF + no mouse reporting         → send arrow key sequences
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
        /// User-configurable scroll settings (set from SessionManager on init)
        nonisolated(unsafe) static var scrollSensitivity: Double = 1.0
        nonisolated(unsafe) static var scrollMaxLines: Int = 5
        /// Accumulated scroll delta for trackpad/magic mouse continuous input
        nonisolated(unsafe) static var accumulatedDelta: Double = 0
        nonisolated(unsafe) static var lastScrollTime: TimeInterval = 0

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
                let mouseMode = terminal.mouseMode

                // === Decision tree ===

                if !isAlternate {
                    // Normal screen → apply scroll sensitivity scaling
                    // Scale the delta to match user preference
                    let scaledDelta = deltaY * scrollSensitivity
                    let ticks = max(1, min(Int(round(abs(scaledDelta))), scrollMaxLines))

                    // Send scaled arrow keys for precise control
                    let arrowSequence: String = if deltaY > 0 {
                        terminal.applicationCursor ? "\u{1B}OB" : "\u{1B}[B"
                    } else {
                        terminal.applicationCursor ? "\u{1B}OA" : "\u{1B}[A"
                    }

                    let combined = String(repeating: arrowSequence, count: ticks)
                    terminal.sendResponse(combined)
                    return nil
                }

                if mouseAllowed, mouseMode != .off {
                    // ALTBUF + mouse reporting → SGR escape sequences
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

                // ALTBUF + no mouse reporting → arrow key simulation
                // Rate-limit: only send once per scroll gesture (~150ms)
                let now = Date.timeIntervalSinceReferenceDate
                let timeSinceLast = now - Self.lastScrollTime

                // If <150ms since last send, skip (still in same gesture)
                guard timeSinceLast > 0.15 else { return nil }

                Self.lastScrollTime = now

                // Use the delta direction, but cap at maxLines
                let ticks = min(scrollMaxLines, max(1, Int(round(abs(deltaY) * scrollSensitivity))))

                Log.ui.debug("[Scroll] delta=\(deltaY), sens=\(scrollSensitivity), max=\(scrollMaxLines), ticks=\(ticks)")

                let arrowSequence: String = if deltaY > 0 {
                    terminal.applicationCursor ? "\u{1B}OA" : "\u{1B}[A"
                } else {
                    terminal.applicationCursor ? "\u{1B}OB" : "\u{1B}[B"
                }

                let combined = String(repeating: arrowSequence, count: ticks)
                terminal.sendResponse(combined)
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
