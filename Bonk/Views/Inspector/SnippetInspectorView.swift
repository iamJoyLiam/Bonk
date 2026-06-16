//
//  SnippetInspectorView.swift
//  Bonk
//
//  Snippet panel inside the right inspector — quick insert + edit.
//

import SwiftData
import SwiftUI

struct SnippetInspectorView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Snippet.sortOrder) private var snippets: [Snippet]
    @Bindable var sessionManager: SessionManager
    @State private var searchText = ""
    @State private var showAddSheet = false
    @State private var editingSnippet: Snippet?

    private var filteredSnippets: [Snippet] {
        if searchText.isEmpty { return snippets }
        let query = searchText.lowercased()
        return snippets.filter {
            $0.name.lowercased().contains(query)
                || $0.command.lowercased().contains(query)
                || $0.category.lowercased().contains(query)
        }
    }

    private var groupedSnippets: [(String, [Snippet])] {
        let grouped = Dictionary(grouping: filteredSnippets) { $0.category }
        return grouped.sorted { $0.key < $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField(i18n.t(.search), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                Spacer()
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help(i18n.t(.addSnippet))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Snippet list
            if filteredSnippets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(i18n.t(.noSnippets))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Button { showAddSheet = true } label: {
                        Label(i18n.t(.addSnippet), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groupedSnippets, id: \.0) { category, items in
                            // Category header — matches sidebar section style
                            HStack {
                                Text(category)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 4)

                            ForEach(items) { snippet in
                                snippetRow(snippet)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            SnippetEditSheet(snippet: nil, modelContext: modelContext)
                .environment(i18n)
        }
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditSheet(snippet: snippet, modelContext: modelContext)
                .environment(i18n)
        }
    }

    // MARK: - Snippet Row

    @ViewBuilder
    private func snippetRow(_ snippet: Snippet) -> some View {
        HStack(spacing: 10) {
            // Content
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(snippet.command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Insert button
            Button { insertSnippet(snippet) } label: {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help(i18n.t(.insertSnippet))

            // Edit button
            Button { editingSnippet = snippet } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(i18n.t(.editSnippet))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button { insertSnippet(snippet) } label: {
                Label(i18n.t(.insertSnippet), systemImage: "arrow.right.circle")
            }
            Button { editingSnippet = snippet } label: {
                Label(i18n.t(.editSnippet), systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                modelContext.delete(snippet)
            } label: {
                Label(i18n.t(.delete), systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func insertSnippet(_ snippet: Snippet) {
        guard let activeTab = sessionManager.activeTab else { return }
        let resolved = snippet.resolve()
        let bytes = Array(resolved.utf8 + [13])
        Task { try? await sessionManager.sendInput(bytes[...], to: activeTab.id) }
    }
}
