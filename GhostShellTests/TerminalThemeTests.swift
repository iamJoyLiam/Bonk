//
//  TerminalThemeTests.swift
//  GhostShellTests
//

import XCTest
@testable import GhostShell

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
        let st = color.swiftTermColor
        XCTAssertEqual(st.red, 65535)
        XCTAssertEqual(st.green, 0)
        XCTAssertEqual(st.blue, 0)
    }

    func testColorSchemeEquatable() {
        let a = LightTheme().colorScheme
        let b = LightTheme().colorScheme
        let c = DarkTheme().colorScheme
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
