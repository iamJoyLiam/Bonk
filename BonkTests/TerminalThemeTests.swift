//
//  TerminalThemeTests.swift
//  BonkTests
//

import XCTest
@testable import Bonk

final class TerminalThemeTests: XCTestCase {

    func testDarkThemeIsDark() {
        XCTAssertTrue(DarkTheme().isDark)
    }

    func testLightThemeIsNotDark() {
        XCTAssertFalse(LightTheme().isDark)
    }

    func testTransparentThemeIsDark() {
        XCTAssertTrue(TransparentTheme().isDark)
    }

    func testTransparentSchemeOpacityClamped() {
        let theme = TransparentTheme()

        let low = theme.colorScheme(opacity: 0.0)
        XCTAssertEqual(low.background.a, 0.1, accuracy: 0.001)

        let high = theme.colorScheme(opacity: 2.0)
        XCTAssertEqual(high.background.a, 1.0, accuracy: 0.001)

        let normal = theme.colorScheme(opacity: 0.5)
        XCTAssertEqual(normal.background.a, 0.5, accuracy: 0.001)
    }

    func testTransparentSchemeIsTransparent() {
        let scheme = TransparentTheme().colorScheme(opacity: 0.5)
        XCTAssertTrue(scheme.isTransparent)
    }

    func testLightSchemeIsNotTransparent() {
        XCTAssertFalse(LightTheme().colorScheme.isTransparent)
    }

    func testAllSchemesHave16Colors() {
        for theme in ThemeRegistry.all {
            XCTAssertEqual(theme.colorScheme.ansiColors.count, 16,
                           "Theme \(theme.id) should have exactly 16 ANSI colors")
        }
    }

    func testRGBAColorSwiftTermConversion() {
        let color = RGBAColor(1.0, 0.0, 0.0)  // pure red
        let swiftTermColor = color.swiftTermColor
        XCTAssertEqual(swiftTermColor.red, 65535)
        XCTAssertEqual(swiftTermColor.green, 0)
        XCTAssertEqual(swiftTermColor.blue, 0)
    }

    func testColorSchemeEquatable() {
        let lightScheme1 = LightTheme().colorScheme
        let lightScheme2 = LightTheme().colorScheme
        let darkScheme = DarkTheme().colorScheme
        XCTAssertEqual(lightScheme1, lightScheme2)
        XCTAssertNotEqual(lightScheme1, darkScheme)
    }
}
