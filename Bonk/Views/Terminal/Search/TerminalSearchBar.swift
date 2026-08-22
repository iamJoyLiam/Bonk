//
//  TerminalSearchBar.swift
//  Bonk
//

import SwiftUI

/// Search bar for terminal content — appears on Cmd+F.
struct TerminalSearchBar: View {
    @Environment(I18n.self) var i18n
    @Binding var searchText: String
    @Binding var isPresented: Bool
    let matchCount: Int
    let currentMatch: Int
    let onNext: () -> Void
    let onPrevious: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: AppStyle.fontBody))

            TextField(i18n.t(.search), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: AppStyle.fontRegular))
                .frame(width: AppStyle.size200)
                .focused($isFocused)
                .onSubmit {
                    if matchCount > 0 { onNext() }
                }

            if !searchText.isEmpty {
                Text("\(currentMatch)/\(matchCount)")
                    .font(.system(size: AppStyle.fontSmall, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: AppStyle.size40)
            }

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
                    .font(.system(size: AppStyle.fontCaption, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(searchText.isEmpty || matchCount == 0)

            Button(action: onNext) {
                Image(systemName: "chevron.down")
                    .font(.system(size: AppStyle.fontCaption, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(searchText.isEmpty || matchCount == 0)

            Button {
                searchText = ""
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: AppStyle.fontCaption, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingS)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(AppStyle.opacityBackgroundLight), radius: 8, y: 4)
        .onAppear {
            // Small delay so the TextField exists before focusing.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                isFocused = true
            }
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }
}
