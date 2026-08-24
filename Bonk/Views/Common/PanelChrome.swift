import SwiftUI

// MARK: - PanelChrome
// Unified header / empty / row chrome for all "list-panel" sheets:
// RecordingListView, WorkspaceListView, JumpHostView, PortForwardView.
// Single source of truth so spacing / icon / count-badge never drifts again.

/// Standard header used at the top of every panel sheet.
struct PanelHeaderView: View {
    @Environment(I18n.self) var i18n
    let icon: String
    let title: String
    let count: Int?
    let countLabel: String?
    var trailing: AnyView? = nil

    init(icon: String, title: String, count: Int? = nil, countLabel: String? = nil, trailing: AnyView? = nil) {
        self.icon = icon
        self.title = title
        self.count = count
        self.countLabel = countLabel
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: AppStyle.spacingM) {
            Image(systemName: icon)
                .font(.system(size: AppStyle.fontMedium, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: AppStyle.iconHero, height: AppStyle.iconHero)
            Text(title)
                .font(.system(size: AppStyle.fontRegular, weight: .semibold))
            Spacer()
            if let count {
                Text(countLabel ?? "\(count)")
                    .font(.system(size: AppStyle.fontCaption))
                    .foregroundStyle(.secondary)
            }
            if let trailing { trailing }
        }
        .padding(.horizontal, AppStyle.spacingXL)
        .padding(.vertical, AppStyle.spacingML)
    }
}

/// Standard empty state for every panel sheet.
struct PanelEmptyView: View {
    let icon: String
    let title: String
    let hint: String?

    var body: some View {
        VStack(spacing: AppStyle.spacingL) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 64, height: 64)
                Image(systemName: icon)
                    .font(.system(size: AppStyle.iconSplash, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            VStack(spacing: AppStyle.spacingXS) {
                Text(title)
                    .font(.system(size: AppStyle.fontMedium, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let hint {
                    Text(hint)
                        .font(.system(size: AppStyle.fontSmall))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: AppStyle.panelWidthSmall + 20)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppStyle.spacingXXL)
    }
}

/// Thin accent progress bar used by RecordingPlaybackView and future panels.
struct PanelProgressBar: View {
    var progress: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.6))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * CGFloat(min(max(progress, 0), 1)))
            }
        }
        .frame(height: 3)
        .clipShape(Capsule())
        .animation(.easeInOut(duration: 0.15), value: progress)
    }
}

/// Row container with consistent hover / padding.
struct PanelRowContainer<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(.horizontal, AppStyle.spacingXL)
            .padding(.vertical, AppStyle.spacingML)
            .contentShape(Rectangle())
    }
}

/// Card background for rows that need it (recording / workspace).
struct PanelCardBackground: ViewModifier {
    var isHovered = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous)
                    .fill(isHovered ? Color(nsColor: .controlBackgroundColor) : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous)
                            .strokeBorder(Color.primary.opacity(isHovered ? AppStyle.opacityStroke : 0), lineWidth: 1)
                    )
            )
    }
}

// MARK: - Add button (plain +)

struct PanelAddButton: View {
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: AppStyle.fontBody, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
