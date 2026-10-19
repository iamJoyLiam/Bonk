//
//  PaneChromeTests.swift
//  BonkTests
//
//  The page is the desktop, so the card is a solid plate and the gutter is
//  only a few points. A translucent plate would be the desktop again.
//

import AppKit
import XCTest
@testable import Bonk

final class PaneChromeTests: XCTestCase {
    func testLightPlateStaysOpaque() {
        let scheme = scheme(RGBAColor(1, 1, 1, 0.2))
        for active in [true, false] {
            assertOpaque(PaneChrome.terminalFill(isActive: active, scheme: scheme))
        }
    }

    func testDarkPlateKeepsItsOwnOpaqueColor() {
        let nord = scheme(RGBAColor(0.180, 0.204, 0.251, 0.4))
        let plate = PaneChrome.terminalFill(isActive: true, scheme: nord)
        assertOpaque(plate)
        XCTAssertLessThan(PaneChrome.luminance(plate), 0.5)
        let red = plate.usingColorSpace(.sRGB)?.redComponent ?? 1
        XCTAssertEqual(red, 0.180, accuracy: 0.01)
    }

    func testGutterIsSixPointsOnEverySide() {
        XCTAssertEqual(AppStyle.cardGutter, 6)
        XCTAssertEqual(AppStyle.cardGutter, AppStyle.spacingS)
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
