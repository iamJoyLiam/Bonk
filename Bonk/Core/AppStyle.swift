import SwiftUI

/// Shared design constants for consistent styling across the app.
enum AppStyle {
    // MARK: - Corner Radius

    static let cornerRadiusSmall: CGFloat = 6
    static let cornerRadiusMedium: CGFloat = 10
    static let cornerRadiusLarge: CGFloat = 14
    static let cornerRadiusCapsule: CGFloat = 20

    // MARK: - Spacing

    static let spacingXXS: CGFloat = 2
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 6
    static let spacingSPlus: CGFloat = 5
    static let spacingM: CGFloat = 8
    static let spacingML: CGFloat = 10
    static let spacingMPlus: CGFloat = 9
    static let spacingL: CGFloat = 12
    static let spacingXL: CGFloat = 16
    static let spacingXLPlus: CGFloat = 14
    static let spacingXXL: CGFloat = 20
    static let spacingIndent: CGFloat = 32
    static let spacingSidebar: CGFloat = 44
    static let spacingTop: CGFloat = 60

    // MARK: - Font Sizes

    static let fontMicro: CGFloat = 7
    static let fontTiny: CGFloat = 8
    static let fontSmallest: CGFloat = 9
    static let fontCaption: CGFloat = 10
    static let fontSmall: CGFloat = 11
    static let fontBody: CGFloat = 12
    static let fontRegular: CGFloat = 13
    static let fontMedium: CGFloat = 14
    static let fontLarge: CGFloat = 16
    static let fontSubtitle: CGFloat = 18
    static let fontXL: CGFloat = 24
    static let fontXXL: CGFloat = 28
    static let fontHero: CGFloat = 36
    static let fontHuge: CGFloat = 40
    static let fontGiant: CGFloat = 44
    static let fontEpic: CGFloat = 56
    static let fontDisplay: CGFloat = 48

    // MARK: - Icon Sizes

    static let iconMicro: CGFloat = 7
    static let iconSmall: CGFloat = 8
    static let iconTiny: CGFloat = 9
    static let iconMedium: CGFloat = 10
    static let iconLarge: CGFloat = 12
    static let iconXL: CGFloat = 14
    static let iconXXL: CGFloat = 16
    static let iconHuge: CGFloat = 18
    static let iconDisplay: CGFloat = 20
    static let iconHero: CGFloat = 24
    static let iconSplash: CGFloat = 36

    // MARK: - Status Dot Sizes

    static let statusDotTiny: CGFloat = 4
    static let statusDotSmall: CGFloat = 6
    static let statusDotMedium: CGFloat = 8
    static let indicatorThin: CGFloat = 2
    static let indicatorMedium: CGFloat = 3

    // MARK: - Button Sizes

    static let buttonSmall: CGFloat = 24
    static let buttonMedium: CGFloat = 28
    static let buttonLarge: CGFloat = 32

    // MARK: - Animations

    static let animationFast: Animation = .easeOut(duration: 0.1)
    static let animationNormal: Animation = .easeInOut(duration: 0.2)
    static let animationSlow: Animation = .easeInOut(duration: 0.3)
    static let animationSpring: Animation = .spring(duration: 0.3)
    static let animationTab: Animation = .smooth(duration: 0.22, extraBounce: 0)

    // MARK: - Opacity

    static let opacityDisabled: Double = 0.5
    static let opacitySecondary: Double = 0.7
    static let opacityHover: Double = 0.8
    static let opacityPressed: Double = 0.6
    static let opacityBackgroundHover: Double = 0.10
    static let opacityBackgroundSubtle: Double = 0.06
    static let opacityBackgroundStrong: Double = 0.12
    static let opacityBackgroundLight: Double = 0.15
    static let opacityBackgroundMute: Double = 0.05
    static let opacityTintActive: Double = 0.28
    static let opacityTintIdle: Double = 0.12
    static let opacityStroke: Double = 0.08
    static let opacityOverlayFaint: Double = 0.07
    static let opacityOverlaySubtle: Double = 0.10
    static let opacityOverlayLight: Double = 0.20
    static let opacityOverlayDim: Double = 0.25
    static let opacityOverlay: Double = 0.30
    static let opacityOverlayStrong: Double = 0.35
    static let opacityOverlayGhost: Double = 0.40

    // MARK: - Window Sizes

    static let settingsWindowWidth: CGFloat = 720
    static let settingsWindowHeight: CGFloat = 500
    static let quickConnectWidth: CGFloat = 400
    static let quickConnectHeight: CGFloat = 500
    static let newConnectionWidth: CGFloat = 400
    static let newConnectionHeight: CGFloat = 350
    static let sftpWindowMinWidth: CGFloat = 800
    static let sftpWindowMinHeight: CGFloat = 500
    static let sftpPaneMinWidth: CGFloat = 250
    static let panelWidthSmall: CGFloat = 300
    static let panelWidthMedium: CGFloat = 420
    static let dialogWidth: CGFloat = 480
    static let dialogHeightSmall: CGFloat = 320
    static let dialogHeightMedium: CGFloat = 400
    static let dialogHeightLarge: CGFloat = 440
    static let dialogHeightXLarge: CGFloat = 480
    static let editorColumnSmall: CGFloat = 30
    static let editorColumnMedium: CGFloat = 80
    static let editorColumnLarge: CGFloat = 150
    static let statsLabelWidth: CGFloat = 52
    static let quakeMinWidth: CGFloat = 600
    static let quakeMinHeight: CGFloat = 400
    static let serialPortWidth: CGFloat = 450
    static let width450: CGFloat = serialPortWidth
    static let sizeHairline: CGFloat = 1
    static let size22: CGFloat = 22
    static let size26: CGFloat = 26
    static let size28: CGFloat = 28
    static let size40: CGFloat = 40
    static let size100: CGFloat = 100
    static let size140: CGFloat = 140
    static let size200: CGFloat = 200
    static let size220: CGFloat = 220

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

    // MARK: - Tab Bar (Ghostty-style capsule)

    static let tabHPadding: CGFloat = spacingM // 8
    static let tabVPadding: CGFloat = spacingXS // 4
    static let tabMinWidth: CGFloat = 72
    static let tabMaxWidth: CGFloat = 148
    static let tabSpacing: CGFloat = spacingS // 6
    static let tabBarHeight: CGFloat = 44
    static let tabBarHPadding: CGFloat = spacingM // 8
    static let tabCornerRadius: CGFloat = 16
    static let tabCloseSize: CGFloat = 16
    static let tabIconClose: CGFloat = 8

    // MARK: - Code Block

    static let codeBlockBackground = Color(nsColor: .controlBackgroundColor)
    static let codeBlockCornerRadius: CGFloat = cornerRadiusSmall

    // MARK: - AI Panel

    static let aiPanelWidth: CGFloat = 320

    // MARK: - Team Sheet

    static let teamContentWidth: CGFloat = 380
    static let teamPickerWidth: CGFloat = 320
    static let teamSheetMinWidth: CGFloat = 460
    static let teamSheetIdealWidth: CGFloat = 480
    static let teamSheetMinHeight: CGFloat = 520
    static let teamSheetIdealHeight: CGFloat = 540
    static let teamPortFieldWidth: CGFloat = 90
    static let teamLiveTerminalHeight: CGFloat = 220
    static let teamInputFieldHeight: CGFloat = 36
}
