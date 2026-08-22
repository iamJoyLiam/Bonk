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
    @State private var showAIGenerate = false
    @State private var aiPrompt = ""
    @State private var aiGeneratedCommand = ""
    @State private var aiIsGenerating = false
    @State private var editingSnippet: Snippet?
    @State private var showAIResult = false

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
            // Search + buttons
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: AppStyle.fontBody))
                TextField(i18n.t(.search), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppStyle.fontRegular))
                Spacer()
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: AppStyle.fontBody))
                }
                .buttonStyle(.plain)
                .help(i18n.t(.addSnippet))

                Button {
                    if AIProviderStore.shared.activeProvider != nil {
                        aiPrompt = ""; aiGeneratedCommand = ""; showAIGenerate = true
                    }
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: AppStyle.fontBody))
                        .foregroundStyle(aiIsGenerating ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(aiIsGenerating || AIProviderStore.shared.activeProvider == nil)
                .help(
                    AIProviderStore.shared.activeProvider == nil
                        ? i18n.t(.configureProviderHint)
                        : i18n.t(.aiAssistant)
                )
            }
            .padding(.horizontal, AppStyle.spacingL)
            .padding(.vertical, AppStyle.spacingM)

            Divider()

            // Snippet list
            if filteredSnippets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: AppStyle.fontHero))
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
                            // Category header
                            HStack {
                                Text(category)
                                    .font(.system(size: AppStyle.fontSmall, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, AppStyle.spacingL)
                            .padding(.top, AppStyle.spacingML)
                            .padding(.bottom, AppStyle.spacingXS)

                            ForEach(items) { snippet in
                                snippetRow(snippet)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            let categories = Array(Set(snippets.map(\.category))).sorted()
            SnippetEditSheet(
                snippet: nil,
                modelContext: modelContext,
                existingCategories: categories
            )
            .environment(i18n)
        }
        .sheet(item: $editingSnippet) { snippet in
            let categories = Array(Set(snippets.map(\.category))).sorted()
            SnippetEditSheet(
                snippet: snippet,
                modelContext: modelContext,
                existingCategories: categories
            )
            .environment(i18n)
        }
        .sheet(isPresented: $showAIGenerate) {
            AIGenerateSheet(
                i18n: i18n,
                prompt: $aiPrompt,
                generatedCommand: $aiGeneratedCommand,
                isGenerating: $aiIsGenerating,
                onSave: { _ in showAIResult = true }
            )
            .onDisappear {
                // Reset AI state when sheet dismisses (Esc or cancel)
                if !showAIResult {
                    aiPrompt = ""
                    aiGeneratedCommand = ""
                    aiIsGenerating = false
                }
            }
        }
        .sheet(isPresented: $showAIResult) {
            SnippetEditSheet(
                snippet: nil,
                modelContext: modelContext,
                initialCommand: aiGeneratedCommand,
                initialName: aiPrompt,
                initialCategory: "AI",
                existingCategories: Array(Set(snippets.map(\.category))).sorted()
            )
            .environment(i18n)
        }
    }

    // MARK: - Snippet Row

    private func snippetRow(_ snippet: Snippet) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.name)
                    .font(.system(size: AppStyle.fontBody, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(snippet.command)
                    .font(.system(size: AppStyle.fontCaption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Insert button
            Button { insertSnippet(snippet) } label: {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: AppStyle.fontMedium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help(i18n.t(.insertSnippet))

            // Edit button
            Button { editingSnippet = snippet } label: {
                Image(systemName: "pencil")
                    .font(.system(size: AppStyle.fontSmall))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(i18n.t(.editSnippet))
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingS)
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
        let resolved = snippet.resolve()
        sessionManager.sendTextToActiveTab(resolved)
        // 归还焦点到终端
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(100))
            NotificationCenter.default.post(name: .focusTerminal, object: nil)
        }
    }
}

// MARK: - AI Generate Sheet

struct AIGenerateSheet: View {
    let i18n: I18n
    @Binding var prompt: String
    @Binding var generatedCommand: String
    @Binding var isGenerating: Bool
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(i18n.t(.describeTask))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                TextField(i18n.t(.describeTask), text: $prompt)
                    .textFieldStyle(.roundedBorder)

                if isGenerating {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(i18n.t(.aiThinking))
                            .foregroundStyle(.secondary)
                    }
                }

                if !generatedCommand.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(i18n.t(.command))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(generatedCommand)
                            .font(.system(size: AppStyle.fontRegular, design: .monospaced))
                            .padding(AppStyle.spacingM)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: AppStyle.cornerRadiusSmall))
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle(i18n.t(.aiAssistant))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(i18n.t(.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack {
                        Button {
                            Task { await generate() }
                        } label: {
                            Label(i18n.t(.execute), systemImage: "sparkles")
                        }
                        .disabled(prompt.isEmpty || isGenerating)

                        if !generatedCommand.isEmpty {
                            Button {
                                onSave(generatedCommand)
                                dismiss()
                            } label: {
                                Label(i18n.t(.save), systemImage: "checkmark")
                            }
                        }
                    }
                }
            }
            .alert(errorMessage, isPresented: $showError) {
                Button(i18n.t(.ok)) {}
            }
        }
        .frame(width: AppStyle.panelWidthMedium, height: 320)
    }

    private func generate() async {
        isGenerating = true
        generatedCommand = ""
        defer { isGenerating = false }

        // Ensure we have an active provider
        guard let provider = AIProviderStore.shared.activeProvider else {
            errorMessage = i18n.t(.noActiveProvider)
            showError = true
            return
        }

        let systemPrompt = """
        You are a terminal command generator. Convert the user's description into a single terminal command.
        Return ONLY the command, no explanation, no markdown, no code blocks.
        If the description is in Chinese, still return an English terminal command.
        """
        let engine = AgentEngine.shared
        engine.activeProvider = provider
        let response = await engine.execute(
            input: prompt,
            mode: .ask,
            context: TerminalContext(),
            systemPromptOverride: systemPrompt
        )

        // Check for errors first
        if let error = engine.lastError {
            errorMessage = error
            showError = true
            return
        }

        // Process response
        if let response, !response.isEmpty {
            let cleaned = response
                .components(separatedBy: .newlines).first ?? response
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            generatedCommand = cleaned
        } else {
            errorMessage = i18n.t(.aiNoResponse)
            showError = true
        }
    }
}
