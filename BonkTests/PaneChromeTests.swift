//
//  PaneChromeTests.swift
//  BonkTests
//
//  The page is the window's liquid glass. A card is either a solid plate or,
//  on macOS 26 and later, the same glass as a toolbar button. A dark glass
//  card stays clear and tints toward its own field. Older systems have no
//  such material, so the setting cannot enable it there.
//

import AppKit
import XCTest
@testable import Bonk

final class PaneChromeTests: XCTestCase {
    func testLightPlateStaysOpaque() {
        let scheme = scheme(RGBAColor(1, 1, 1, 0.2))
        for active in [true, false] {
            assertOpaque(PaneChrome.terminalFill(isActive: active, scheme: scheme, glass: false))
        }
    }

    func testDarkPlateKeepsItsOwnOpaqueColor() {
        let nord = scheme(RGBAColor(0.180, 0.204, 0.251, 0.4))
        let plate = PaneChrome.terminalFill(isActive: true, scheme: nord, glass: false)
        assertOpaque(plate)
        XCTAssertLessThan(PaneChrome.luminance(plate), 0.5)
        let red = plate.usingColorSpace(.sRGB)?.redComponent ?? 1
        XCTAssertEqual(red, 0.180, accuracy: 0.01)
    }

    func testGlassCardClearsTheGrid() {
        let scheme = scheme(RGBAColor(1, 1, 1))
        let plate = PaneChrome.terminalFill(isActive: true, scheme: scheme, glass: true)
        let alpha = plate.usingColorSpace(.sRGB)?.alphaComponent ?? 1
        XCTAssertEqual(alpha, 0, accuracy: 0.001)
    }

    func testDarkGlassStaysClearAndTintsTowardItsField() {
        let dark = scheme(RGBAColor(0.118, 0.118, 0.118, 0.4))
        let plate = PaneChrome.terminalFill(isActive: true, scheme: dark, glass: true)
        let alpha = plate.usingColorSpace(.sRGB)?.alphaComponent ?? 1
        XCTAssertEqual(alpha, 0, accuracy: 0.001)

        let tint = PaneChrome.glassTint(dark)
        let rgb = tint?.usingColorSpace(.sRGB)
        XCTAssertEqual(rgb?.redComponent ?? 0, 0.118, accuracy: 0.01)
        XCTAssertEqual(rgb?.alphaComponent ?? 0, PaneChrome.darkGlassTintAlpha, accuracy: 0.001)
        XCTAssertNil(PaneChrome.glassTint(scheme(RGBAColor(1, 1, 1))))
    }

    func testGlassCardDefaultsOnOnlyWhereTheSystemHasIt() {
        XCTAssertFalse(PaneChrome.glassCardEnabled(preference: nil, systemSupportsGlass: false))
        XCTAssertFalse(PaneChrome.glassCardEnabled(preference: true, systemSupportsGlass: false))
        XCTAssertTrue(PaneChrome.glassCardEnabled(preference: nil, systemSupportsGlass: true))
        XCTAssertTrue(PaneChrome.glassCardEnabled(preference: true, systemSupportsGlass: true))
        XCTAssertFalse(PaneChrome.glassCardEnabled(preference: false, systemSupportsGlass: true))
    }

    func testGutterIsSixPointsOnEverySide() {
        XCTAssertEqual(AppStyle.cardGutter, 6)
        XCTAssertEqual(AppStyle.cardGutter, AppStyle.spacingS)
    }

    func testTabSwitchDetachesThePaneUnderItsOwnTab() {
        let firstTab = UUID()
        let secondTab = UUID()
        let firstPane = UUID()
        let mounted = PaneMount.previous(paneID: firstPane, tabID: firstTab, fallbackTabID: secondTab)
        XCTAssertEqual(mounted?.paneID, firstPane)
        XCTAssertEqual(mounted?.tabID, firstTab)
        XCTAssertNil(PaneMount.previous(paneID: nil, tabID: firstTab, fallbackTabID: secondTab))
    }

    private func assertOpaque(_ color: NSColor) {
        let alpha = color.usingColorSpace(.sRGB)?.alphaComponent ?? 0
        XCTAssertEqual(alpha, 1, accuracy: 0.001)
    }

    private func scheme(_ background: RGBAColor) -> TerminalColorScheme {
        TerminalColorScheme(
            id: "plate",
            name: "plate",
            background: background,
            foreground: RGBAColor(0, 0, 0),
            cursor: RGBAColor(0, 0, 0),
            ansiColors: Array(repeating: RGBAColor(0, 0, 0), count: 16)
        )
    }
}
