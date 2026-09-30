//
//  TerminalContainerView+ThemeObservers.swift
//  Bonk
//
//  Notification observers for theme, font, selection, and focus changes.
//

import SwiftTerm

#if os(macOS)
    import AppKit

    extension ContainerTerminalCoordinator {
        func observeThemeChanges() {
            // Font changes — bypass SwiftUI observation chain (same pattern as theme)
            fontObserver = NotificationCenter.default.addObserver(
                forName: .terminalFontDidChange, object: nil, queue: .main
            ) { [weak self] notification in
                let fontFamily = (notification.object as? String) ?? "SF Mono"
                let fontSize = (notification.userInfo?["fontSize"] as? Double) ?? 14.0
                MainActor.assumeIsolated {
                guard let self, let terminal = self.terminalView else { return }
                let size = CGFloat(fontSize)
                let newFont = switch fontFamily {
                case "Menlo":
                    NSFont(name: "Menlo", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                case "Monaco":
                    NSFont(name: "Monaco", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                case "Courier New":
                    NSFont(name: "Courier New", size: size)
                        ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                case "JetBrains Mono":
                    NSFont(name: "JetBrains Mono", size: size)
                        ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                default:
                    NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                }
                terminal.font = newFont
                terminal.needsDisplay = true
                }
            }

            themeObserver = NotificationCenter.default.addObserver(
                forName: .terminalThemeDidChange, object: nil, queue: .main
            ) { [weak self] notification in
                let scheme = notification.object as? TerminalColorScheme
                MainActor.assumeIsolated {
                guard let self, let terminal = self.terminalView,
                      let scheme else { return }
                terminal.nativeBackgroundColor = scheme.background.nsColor
                terminal.nativeForegroundColor = scheme.foreground.nsColor
                terminal.installColors(scheme.swiftTermColors)
                }
            }

            // NOTE: `.requestTerminalSelection` is deliberately NOT handled
            // here. This view is the single-pane terminal, so a responder placed
            // here does not exist at all for a split tab. It also used to reply
            // with the notification's own object — which every sender posts as
            // nil — so it always answered "" and never called `getSelection()`.
            // `TerminalSelectionResponder` owns the round trip.

            // Select all text in terminal
            selectAllObserver = NotificationCenter.default.addObserver(
                forName: .selectAllInTerminal,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                guard let self, let terminal = self.terminalView else { return }
                terminal.selectAll()
                }
            }

            // Focus terminal
            focusObserver = NotificationCenter.default.addObserver(
                forName: .focusTerminal,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                guard let self, let terminal = self.terminalView else { return }
                terminal.window?.makeFirstResponder(terminal)
                }
            }
        }

        func removeThemeObserver() {
            if let observer = themeObserver {
                NotificationCenter.default.removeObserver(observer)
                themeObserver = nil
            }
            if let observer = fontObserver {
                NotificationCenter.default.removeObserver(observer)
                fontObserver = nil
            }
            if let observer = selectAllObserver {
                NotificationCenter.default.removeObserver(observer)
                selectAllObserver = nil
            }
            if let observer = focusObserver {
                NotificationCenter.default.removeObserver(observer)
                focusObserver = nil
            }
        }
    }

#endif
