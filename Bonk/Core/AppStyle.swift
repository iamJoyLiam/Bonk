import SwiftUI

/// Shared design constants for consistent styling across the app.
enum AppStyle {
    // MARK: - Corner Radius
    static let cornerRadiusSmall: CGFloat = 6
    static let cornerRadiusMedium: CGFloat = 10
    static let cornerRadiusLarge: CGFloat = 14
    static let cornerRadiusCapsule: CGFloat = 20

    // MARK: - Spacing
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 6
    static let spacingM: CGFloat = 8
    static let spacingL: CGFloat = 12
    static let spacingXL: CGFloat = 16

    // MARK: - Font Sizes
    static let fontCaption: CGFloat = 10
    static let fontSmall: CGFloat = 11
    static let fontBody: CGFloat = 12
    static let fontRegular: CGFloat = 13

    // MARK: - Icon Sizes
    static let iconSmall: CGFloat = 8
    static let iconMedium: CGFloat = 10
    static let iconLarge: CGFloat = 12

    // MARK: - Animations
    static let animationFast: Animation = .easeOut(duration: 0.1)
    static let animationNormal: Animation = .easeInOut(duration: 0.2)
    static let animationSpring: Animation = .spring(duration: 0.3)

    // MARK: - AI Rainbow Gradient
    static let aiRainbowColors: [Color] = [
        Color(red: 1.0, green: 0.0, blue: 0.4),
        Color(red: 1.0, green: 0.3, blue: 0.0),
        Color(red: 1.0, green: 0.8, blue: 0.0),
        Color(red: 0.2, green: 0.8, blue: 0.2),
        Color(red: 0.0, green: 0.7, blue: 1.0),
        Color(red: 0.4, green: 0.1, blue: 0.9),
        Color(red: 1.0, green: 0.0, blue: 0.4),
    ]

    // MARK: - AI Panel
    static let aiPanelWidth: CGFloat = 320
}
