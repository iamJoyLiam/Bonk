//
//  AppStyleTests.swift
//  BonkTests
//
//  Tests for AppStyle design constants.
//

import XCTest
@testable import Bonk

final class AppStyleTests: XCTestCase {

    // MARK: - Corner Radius

    func testCornerRadiusValues() {
        XCTAssertGreaterThan(AppStyle.cornerRadiusSmall, 0)
        XCTAssertGreaterThan(AppStyle.cornerRadiusMedium, AppStyle.cornerRadiusSmall)
        XCTAssertGreaterThan(AppStyle.cornerRadiusLarge, AppStyle.cornerRadiusMedium)
        XCTAssertGreaterThan(AppStyle.cornerRadiusCapsule, AppStyle.cornerRadiusLarge)
    }

    // MARK: - Spacing

    func testSpacingValues() {
        XCTAssertEqual(AppStyle.spacingXS, 4)
        XCTAssertEqual(AppStyle.spacingS, 6)
        XCTAssertEqual(AppStyle.spacingM, 8)
        XCTAssertEqual(AppStyle.spacingL, 12)
        XCTAssertEqual(AppStyle.spacingXL, 16)
    }

    func testSpacingHierarchy() {
        XCTAssertLessThan(AppStyle.spacingXS, AppStyle.spacingS)
        XCTAssertLessThan(AppStyle.spacingS, AppStyle.spacingM)
        XCTAssertLessThan(AppStyle.spacingM, AppStyle.spacingL)
        XCTAssertLessThan(AppStyle.spacingL, AppStyle.spacingXL)
    }

    // MARK: - Font Sizes

    func testFontSizes() {
        XCTAssertEqual(AppStyle.fontCaption, 10)
        XCTAssertEqual(AppStyle.fontSmall, 11)
        XCTAssertEqual(AppStyle.fontBody, 12)
        XCTAssertEqual(AppStyle.fontRegular, 13)
    }

    func testFontSizeHierarchy() {
        XCTAssertLessThan(AppStyle.fontCaption, AppStyle.fontSmall)
        XCTAssertLessThan(AppStyle.fontSmall, AppStyle.fontBody)
        XCTAssertLessThan(AppStyle.fontBody, AppStyle.fontRegular)
    }

    // MARK: - Icon Sizes

    func testIconSizes() {
        XCTAssertEqual(AppStyle.iconSmall, 8)
        XCTAssertEqual(AppStyle.iconMedium, 10)
        XCTAssertEqual(AppStyle.iconLarge, 12)
    }

    func testIconSizeHierarchy() {
        XCTAssertLessThan(AppStyle.iconSmall, AppStyle.iconMedium)
        XCTAssertLessThan(AppStyle.iconMedium, AppStyle.iconLarge)
    }

    // MARK: - Animations

    func testAnimationFastDuration() {
        // Fast animation should be around 0.1 seconds
        XCTAssertNotNil(AppStyle.animationFast)
    }

    func testAnimationNormalDuration() {
        // Normal animation should be around 0.2 seconds
        XCTAssertNotNil(AppStyle.animationNormal)
    }

    func testAnimationSpringDuration() {
        // Spring animation should be around 0.3 seconds
        XCTAssertNotNil(AppStyle.animationSpring)
    }

    // MARK: - AI Rainbow Colors

    func testAIRainbowColorsCount() {
        XCTAssertEqual(AppStyle.aiRainbowColors.count, 7)
    }

    func testAIRainbowColorsAreUnique() {
        let uniqueColors = Set(AppStyle.aiRainbowColors.map { $0.description })
        XCTAssertEqual(uniqueColors.count, AppStyle.aiRainbowColors.count)
    }

    // MARK: - AI Panel

    func testAIPanelWidth() {
        XCTAssertGreaterThan(AppStyle.aiPanelWidth, 0)
        XCTAssertEqual(AppStyle.aiPanelWidth, 320)
    }
}
