//
//  CommandPaletteView.swift
//  Bonk
//

import SwiftUI

/// A command entry for the command palette.
struct PaletteCommand: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let category: String
    let icon: String
    let shortcut: String?
    let action: () -> Void

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PaletteCommand, rhs: PaletteCommand) -> Bool {
        lhs.id == rhs.id
    }
}

/// Command palette — Cmd+Shift+P to open, fuzzy search all commands.
struct CommandPaletteView: View {
    @EnvironmentObject var i18n: I18n
    @Binding var isPresented: Bool
    let commands: [PaletteCommand]

    @State private var searchText = ""
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    private var filteredCommands: [PaletteCommand] {
        if searchText.isEmpty {
            return commands
        }
        let query = searchText.lowercased()
        return commands.filter { cmd in
            cmd.name.lowercased().contains(query)
                || cmd.category.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(i18n.t(.searchCommands), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isSearchFocused)
                    .onChange(of: searchText) { _, _ in
                        selectedIndex = 0
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Command list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                            commandRow(command, index: index)
                                .id(index)
                        }
                    }
                }
                .onChange(of: selectedIndex) { _, newIndex in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
            .frame(maxHeight: 400)
        }
        .frame(width: 480)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        .onAppear {
            isSearchFocused = true
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onKeyPress(.return) {
            if let cmd = filteredCommands[safe: selectedIndex] {
                isPresented = false
                cmd.action()
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < filteredCommands.count - 1 {
                selectedIndex += 1
            }
            return .handled
        }
    }

    @ViewBuilder
    private func commandRow(_ command: PaletteCommand, index: Int) -> some View {
        let isSelected = index == selectedIndex

        Button {
            isPresented = false
            command.action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: command.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(command.name)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? .white : .primary)

                    Text(command.category)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }

                Spacer()

                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                selectedIndex = index
            }
        }
    }
}

// Safe array subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
