//
//  TabLayoutView.swift
//  Bonk
//
//  Renders a tab's layout tree recursively with drag-to-split.
//

import SwiftUI
import UniformTypeIdentifiers

struct TabLayoutView: View {
    let tab: TerminalTab
    let sessionManager: SessionManager
    let colorScheme: TerminalColorScheme
    let preferences: UserPreferences
    let cursorStyle: String
    let cursorBlink: Bool
    @State private var isDragOver = false

    var body: some View {
        ZStack {
            LayoutNodeView(
                node: tab.layout.root,
                activePaneID: tab.activePaneID ?? UUID(),
                tab: tab,
                sessionManager: sessionManager,
                colorScheme: colorScheme,
                preferences: preferences,
                cursorStyle: cursorStyle,
                cursorBlink: cursorBlink
            )

            // Drop indicator overlay
            if isDragOver {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "plus.rectangle.on.rectangle")
                                .font(.system(size: 24))
                            Text("Drop to split")
                                .font(.caption)
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.15), value: isDragOver)
            }
        }
        .onDrop(of: [.utf8PlainText], isTargeted: $isDragOver) { providers, _ in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                guard let uuidString = string as? String,
                      let sourceTabID = UUID(uuidString: uuidString),
                      sourceTabID != tab.id else { return }
                Task { @MainActor in
                    print("[DROP] ✅ source=\(sourceTabID), target=\(tab.id)")
                    sessionManager.addPaneFromTab(sourceTabID, to: tab.id, position: .right)
                }
            }
            return true
        }
    }
}
