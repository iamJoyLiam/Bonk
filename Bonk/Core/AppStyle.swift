import SwiftUI

/// Shared design constants for consistent styling across the app.
enum AppStyle {
    // MARK: - Corner Radius

    static let cornerRadiusSmall: CGFloat = 6
    static let cornerRadiusMedium: CGFloat = 10
    static let cornerRadiusLarge: CGFloat = 14
    static let cornerRadiusCapsule: CGFloat = 20

    // MARK: - Toolbar rings

    /// Size of the circular progress rings in the main toolbar (server CPU /
    /// memory / disk, and SFTP transfers).
    ///
    /// One token for all of them, deliberately. They were sized independently —
    /// 32×30 for the server rings, 38×34 for SFTP — and the mismatch read as one
    /// item being broken rather than as two designs. Sharing the value is what
    /// keeps them equal when either side is adjusted.
    ///
    /// **Square, and that is deliberate.** Each ring draws its circle on the
    /// *shortest* edge, so a 42×34 item rendered a 29pt circle (34 − 2×2.5 inset)
    /// and left 6.5pt of dead space on each side. The toolbar then added its own
    /// item spacing on top, so four rings in a row read as four small circles
    /// separated by wide voids — visibly looser than the team and serial icons
    /// beside them, which are plain `item.image` items on a standard compact
    /// footprint. The width was the dead space, not the toolbar's spacing.
    ///
    /// Matching width to height removes it: the item is now exactly as wide as the
    /// ring it draws, and the only inset left is the stroke.
    static let toolbarRingSize = NSSize(width: 34, height: 34)

    /// Inset applied to the ring's square before the circle is drawn.
    ///
    /// Exactly half the stroke width, and that is the whole point: the stroke
    /// straddles the path, so an inset of `lineWidth / 2` puts the stroke's **outer**
    /// edge on the item's boundary. Anything larger is dead space the toolbar
    /// reserves but nothing paints in, which is what made four rings in a row read
    /// as further apart than the image items beside them — the toolbar's own spacing
    /// applies to both, so the difference could only be this.
    ///
    /// Shared by both ring controls so they cannot drift apart, which is the same
    /// mistake that had the SFTP and server rings at different sizes in the first
    /// place.
    static let ringStrokeInset: CGFloat = 1.5

    /// Stroke width of a toolbar ring's track and progress arc.
    static let ringLineWidth: CGFloat = 3

    /// Point size for text drawn inside a toolbar ring.
    ///
    /// Stepped down for wider strings so `100%` still fits the ring's inner
    /// width; see `ServerResourceRingControl.drawText`.
    static let ringTextFontSize: CGFloat = 10
    static let ringTextFontSizeNarrow: CGFloat = 8.5

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

    /// Painted thickness of a split divider. The mouse target is wider.
    static let splitDividerThickness: CGFloat = 1

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

    // MARK: - Tab Bar
    //
    // The system window tab bar, which is also how TablePro draws the tabs
    // for an open table: a 36pt band holding a 28pt track, 24pt tabs inset
    // 2pt inside it, and the new-tab button outside the track.

    static let tabBandHeight: CGFloat = 36
    static let tabTrackHeight: CGFloat = 28
    static let tabHeight: CGFloat = 24
    static let tabTrackPadding: CGFloat = spacingXXS // 2
    static let tabStripInset: CGFloat = spacingM // 8
    static let tabTrackSpacing: CGFloat = spacingXS // 4
    static let tabNewButtonSize: CGFloat = buttonMedium // 28
    static let tabMinWidth: CGFloat = 120
    static let tabSeparatorHeight: CGFloat = 16
    static let tabAccessoryWidth: CGFloat = 16
    static let tabAccessoryInset: CGFloat = 5
    static let tabHairline: CGFloat = 0.5
    static let tabBarHeight: CGFloat = tabBandHeight
    static let tabIconClose: CGFloat = fontSmallest // 9
    /// Quake panel corner. Kept under the old name so that clip does not move.
    static let tabCornerRadius: CGFloat = 16

    /// Equal share of the track, but never narrower than a readable title.
    static func tabWidth(forTrack usable: CGFloat, count: Int) -> CGFloat {
        let divisor = CGFloat(max(count, 1))
        return max(usable / divisor, tabMinWidth)
    }

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
