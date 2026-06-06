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
                guard let self, let terminal = terminalView else { return }
                let fontFamily = (notification.object as? String) ?? "SF Mono"
                let fontSize = (notification.userInfo?["fontSize"] as? Double) ?? 14.0
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

            themeObserver = NotificationCenter.default.addObserver(
                forName: .terminalThemeDidChange, object: nil, queue: .main
            ) { [weak self] notification in
                guard let self, let terminal = terminalView,
                      let scheme = notification.object as? TerminalColorScheme else { return }
                terminal.nativeBackgroundColor = scheme.background.nsColor
                terminal.nativeForegroundColor = scheme.foreground.nsColor
                terminal.installColors(scheme.swiftTermColors)
            }

            // Selection request → respond with selected text
            NotificationCenter.default.addObserver(
                forName: .requestTerminalSelection,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, let terminal = terminalView else { return }
                let selectedText = terminal.getSelection()
                NotificationCenter.default.post(name: .terminalSelectionResponse, object: selectedText)
            }

            // Select all text in terminal
            NotificationCenter.default.addObserver(
                forName: .selectAllInTerminal,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, let terminal = terminalView else { return }
                terminal.selectAll()
            }

            // Focus terminal
            NotificationCenter.default.addObserver(
                forName: .focusTerminal,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, let terminal = terminalView else { return }
                terminal.window?.makeFirstResponder(terminal)
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
        }
    }

#endif
