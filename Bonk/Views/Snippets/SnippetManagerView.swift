//
//  SnippetManagerView.swift
//  Bonk
//

import SwiftData
import SwiftUI

/// Manages command snippets — add, edit, delete, insert.
struct SnippetManagerView: View {
    @Environment(I18n.self) var i18n
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Snippet.sortOrder) private var snippets: [Snippet]
    @Binding var isPresented: Bool
    let onInsert: (String) -> Void

    @State private var editingSnippet: Snippet?
    @State private var showAddSheet = false
    @State private var searchText = ""

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
            // Header
            HStack {
                Image(systemName: "text.badge.plus")
                    .foregroundStyle(.blue)
                Text(i18n.t(.snippets))
                    .font(.headline)
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help(i18n.t(.addSnippet))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField(i18n.t(.search), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 16)
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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groupedSnippets, id: \.0) { category, items in
                            Section {
                                ForEach(items) { snippet in
                                    snippetRow(snippet)
                                }
                            } header: {
                                HStack {
                                    Text(category)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(Color(nsColor: .controlBackgroundColor))
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .sheet(isPresented: $showAddSheet) {
            SnippetEditSheet(snippet: nil, modelContext: modelContext, existingCategories: Array(Set(snippets.map { $0.category })).sorted())
                .environment(i18n)
        }
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditSheet(snippet: snippet, modelContext: modelContext, existingCategories: Array(Set(snippets.map { $0.category })).sorted())
                .environment(i18n)
        }
    }

    @ViewBuilder
    private func snippetRow(_ snippet: Snippet) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.name)
                    .font(.system(size: 13, weight: .medium))
                Text(snippet.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                let resolved = snippet.resolve()
                onInsert(resolved)
                isPresented = false
            } label: {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help(i18n.t(.insertSnippet))

            Button {
                editingSnippet = snippet
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                let resolved = snippet.resolve()
                onInsert(resolved)
                isPresented = false
            } label: {
                Label(i18n.t(.insertSnippet), systemImage: "arrow.right.circle")
            }
            Button {
                editingSnippet = snippet
            } label: {
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
}

// MARK: - Snippet Edit Sheet

struct SnippetEditSheet: View {
    @Environment(I18n.self) var i18n
    @Environment(\.dismiss) private var dismiss
    let snippet: Snippet?
    let modelContext: ModelContext
    var initialCommand: String = ""
    var initialName: String = ""
    var initialCategory: String = ""
    var existingCategories: [String] = []

    @State private var name = ""
    @State private var command = ""
    @State private var category = "General"
    @State private var customCategory = ""
    @State private var useCustomCategory = false

    private var allCategories: [String] {
        var cats = existingCategories
        if !cats.contains("General") { cats.insert("General", at: 0) }
        return cats.sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(i18n.t(.name)) {
                    TextField(i18n.t(.name), text: $name)
                }

                Section(i18n.t(.command)) {
                    TextEditor(text: $command)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 80)
                }

                Section(i18n.t(.snippetCategory)) {
                    if useCustomCategory {
                        HStack {
                            TextField(i18n.t(.snippetCategory), text: $customCategory)
                            Button { useCustomCategory = false } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Picker(i18n.t(.snippetCategory), selection: $category) {
                            ForEach(allCategories, id: \.self) { cat in
                                Text(cat).tag(cat)
                            }
                            Text(i18n.t(.custom)).tag("__custom__")
                        }
                        .onChange(of: category) { _, newValue in
                            if newValue == "__custom__" {
                                useCustomCategory = true
                                customCategory = ""
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(snippet == nil ? i18n.t(.addSnippet) : i18n.t(.editSnippet))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(i18n.t(.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(i18n.t(.save)) {
                        save()
                        dismiss()
                    }
                    .disabled(name.isEmpty || command.isEmpty)
                }
            }
            .onAppear {
                if let snippet {
                    name = snippet.name
                    command = snippet.command
                    category = snippet.category
                } else {
                    if !initialName.isEmpty { name = initialName }
                    if !initialCommand.isEmpty { command = initialCommand }
                    if !initialCategory.isEmpty {
                        if existingCategories.contains(initialCategory) {
                            category = initialCategory
                        } else {
                            useCustomCategory = true
                            customCategory = initialCategory
                        }
                    }
                }
            }
        }
        .frame(width: 480)
    }

    private func save() {
        let finalCategory = useCustomCategory ? (customCategory.isEmpty ? "General" : customCategory) : category
        if let snippet {
            snippet.name = name
            snippet.command = command
            snippet.category = finalCategory
        } else {
            let newSnippet = Snippet(
                name: name,
                command: command,
                category: finalCategory
            )
            modelContext.insert(newSnippet)
        }
    }
}
