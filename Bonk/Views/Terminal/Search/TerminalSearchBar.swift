//
//  TerminalSearchBar.swift
//  Bonk
//

import SwiftUI

/// Search bar for terminal content — appears on Cmd+F.
struct TerminalSearchBar: View {
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
                .font(.system(size: 12))

            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 200)
                .focused($isFocused)
                .onSubmit {
                    if matchCount > 0 { onNext() }
                }

            if !searchText.isEmpty {
                Text("\(currentMatch)/\(matchCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40)
            }

            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(searchText.isEmpty || matchCount == 0)

            Button(action: onNext) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(searchText.isEmpty || matchCount == 0)

            Button {
                searchText = ""
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .onAppear {
            isFocused = true
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }
}
