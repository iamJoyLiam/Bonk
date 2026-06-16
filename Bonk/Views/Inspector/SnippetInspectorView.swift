//
//  SnippetInspectorView.swift
//  Bonk
//
//  Snippet panel inside the right inspector — quick insert, no full management.
//

import SwiftData
import SwiftUI

struct SnippetInspectorView: View {
    @EnvironmentObject var i18n: I18n
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Snippet.sortOrder) private var snippets: [Snippet]
    @Bindable var sessionManager: SessionManager
    @State private var searchText = ""
    @State private var showAddSheet = false

    private var filteredSnippets: [Snippet] {
        if searchText.isEmpty { return snippets }
        let query = searchText.lowercased()
        return snippets.filter {
            $0.name.lowercased().contains(query)
                || $0.command.lowercased().contains(query)
        }
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
                    Button {
                        showAddSheet = true
                    } label: {
                        Label(i18n.t(.addSnippet), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredSnippets) { snippet in
                            snippetRow(snippet)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            SnippetEditSheet(snippet: nil, modelContext: modelContext)
                .environmentObject(i18n)
        }
    }

    @ViewBuilder
    private func snippetRow(_ snippet: Snippet) -> some View {
        Button {
            insertSnippet(snippet)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(snippet.command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                insertSnippet(snippet)
            } label: {
                Label(i18n.t(.insertSnippet), systemImage: "arrow.right.circle")
            }
            Divider()
            Button(role: .destructive) {
                modelContext.delete(snippet)
            } label: {
                Label(i18n.t(.delete), systemImage: "trash")
            }
        }
    }

    private func insertSnippet(_ snippet: Snippet) {
        guard let activeTab = sessionManager.activeTab else { return }
        let resolved = snippet.resolve()
        let bytes = Array(resolved.utf8 + [13]) // 13 = Enter
        Task { try? await sessionManager.sendInput(bytes[...], to: activeTab.id) }
    }
}
