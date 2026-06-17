//
//  UserPreferences.swift
//  Bonk
//
//  Created by Joy Liam on 2026/5/25.
//

import Foundation
import SwiftData

/// User preferences persisted via SwiftData.
/// Note: Terminal theme (colorSchemeID, terminalOpacity) moved to ThemeManager (@AppStorage)
/// for instant propagation without @Query latency.
///
/// Singleton pattern: `ensurePreferences()` in onAppear inserts if empty.
/// Views use `@Query` + `first ?? UserPreferences()` as transient fallback for first render.
@Model
final class UserPreferences {
    var fontSize: Double
    var fontFamily: String
    var lineHeight: Double
    var defaultPort: Int
    var scrollbackLines: Int
    var optionAsMeta: Bool
    var mouseReporting: Bool
    var cursorStyle: String // "block", "underline", "bar"
    var cursorBlink: Bool
    var copyOnSelect: Bool
    var escDismissAI: Bool
    var hostAutoFillClear: Bool // true = clear on tap, false = allow edit
    var aiDirectSubmit: Bool // true = directly submit selected text, false = show in input
    // General
    var checkForUpdates: Bool

    init(
        fontSize: Double = 14,
        fontFamily: String = "SF Mono",
        lineHeight: Double = 1.2,
        defaultPort: Int = 22,
        scrollbackLines: Int = 10000,
        optionAsMeta: Bool = true,
        mouseReporting: Bool = true,
        cursorStyle: String = "block",
        cursorBlink: Bool = true,
        copyOnSelect: Bool = false,
        escDismissAI: Bool = true,
        hostAutoFillClear: Bool = true,
        aiDirectSubmit: Bool = true,
        checkForUpdates: Bool = true
    ) {
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.lineHeight = lineHeight
        self.defaultPort = defaultPort
        self.scrollbackLines = scrollbackLines
        self.optionAsMeta = optionAsMeta
        self.mouseReporting = mouseReporting
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.copyOnSelect = copyOnSelect
        self.escDismissAI = escDismissAI
        self.hostAutoFillClear = hostAutoFillClear
        self.aiDirectSubmit = aiDirectSubmit
        self.checkForUpdates = checkForUpdates
    }
}
