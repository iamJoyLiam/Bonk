import SwiftUI

// MARK: - BonkFormScaffold
// One NavigationStack + Form wrapper for every Add/Edit sheet so frame,
// formStyle, toolbar placement and scrollContentBackground never drift.
// Keeps AddHostSheet / JumpHostEditSheet / KeychainManagerView / SnippetEditSheet
// / PortForwardEditSheet / GroupEditSheet aligned without copy-paste.

struct BonkFormScaffold<Content: View>: View {
    @Environment(I18n.self) private var i18n
    let title: String
    var minWidth: CGFloat = AppStyle.panelWidthMedium
    var idealHeight: CGFloat?
    var content: Content

    /// When nil, no toolbar is rendered (caller owns toolbar).
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    var saveTitle: String?
    var saveDisabled: Bool = false

    init(
        title: String,
        minWidth: CGFloat = AppStyle.panelWidthMedium,
        idealHeight: CGFloat? = nil,
        onCancel: (() -> Void)? = nil,
        onSave: (() -> Void)? = nil,
        saveTitle: String? = nil,
        saveDisabled: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.minWidth = minWidth
        self.idealHeight = idealHeight
        self.onCancel = onCancel
        self.onSave = onSave
        self.saveTitle = saveTitle
        self.saveDisabled = saveDisabled
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .navigationTitle(title)
                .toolbar {
                    if let onCancel {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(i18n.t(.cancel)) { onCancel() }
                                .keyboardShortcut(.cancelAction)
                        }
                    }
                    if let onSave, let saveTitle {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(saveTitle, action: onSave)
                                .disabled(saveDisabled)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                }
        }
        .frame(minWidth: minWidth, idealWidth: minWidth, idealHeight: idealHeight)
        .environment(\.locale, Locale(identifier: i18n.lang))
    }
}

// MARK: - Convenience: sheet chrome modifier for panel lists

extension View {
    /// Standard frame + background for every panel-sheet (list panels, not forms).
    func panelSheetChrome(minWidth: CGFloat = AppStyle.quickConnectWidth, minHeight: CGFloat = AppStyle.panelWidthSmall) -> some View {
        self.frame(minWidth: minWidth, minHeight: minHeight)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
