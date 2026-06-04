//
//  ThemeRegistryTests.swift
//  GhostShellTests
//

import XCTest
@testable import GhostShell

final class ThemeRegistryTests: XCTestCase {

    func testAllThemesContainsBuiltinThemes() {
        let all = ThemeRegistry.all
        XCTAssertTrue(all.count >= 9)  // light, dark, transparent, dracula, tokyo, gruvbox, catppuccin, nord, solarized
    }

    func testThemeByIDReturnsCorrectTheme() {
        let theme = ThemeRegistry.theme(byID: "dracula")
        XCTAssertNotNil(theme)
        XCTAssertEqual(theme?.name, "Dracula")
    }

    func testThemeByIDReturnsNilForUnknown() {
        XCTAssertNil(ThemeRegistry.theme(byID: "nonexistent"))
    }

    func testPrimaryThemesContainLightAndDark() {
        let primary = ThemeRegistry.primary
        let ids = primary.map(\.id)
        XCTAssertTrue(ids.contains("light"))
        XCTAssertTrue(ids.contains("dark"))
    }

    func testExtraThemesContainDracula() {
        let extra = ThemeRegistry.extra
        let ids = extra.map(\.id)
        XCTAssertTrue(ids.contains("dracula"))
    }

    func testExtraThemesExcludeTransparent() {
        let extra = ThemeRegistry.extra
        let ids = extra.map(\.id)
        XCTAssertFalse(ids.contains("transparent"))
    }

    func testRegisterPluginTheme() {
        struct PluginTheme: TerminalTheme {
            let id = "plugin-test"
            let name = "Plugin Test"
            let isDark = false
            let colorScheme = TerminalColorScheme(
                id: "plugin-test", name: "Plugin Test",
                background: RGBAColor(1, 1, 1),
                foreground: RGBAColor(0, 0, 0),
                cursor: RGBAColor(0, 0, 0),
                ansiColors: Array(repeating: RGBAColor(0, 0, 0), count: 16)
            )
        }

        ThemeRegistry.register(PluginTheme())
        let found = ThemeRegistry.theme(byID: "plugin-test")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "Plugin Test")
    }
}
