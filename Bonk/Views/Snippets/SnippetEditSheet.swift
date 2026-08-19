//
//  SnippetEditSheet.swift
//  Bonk
//

import SwiftData
import SwiftUI

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