//  CommandIntelligenceAssembly.swift
//  Bonk
//
//  Composition root for Command Intelligence — configures workspace, pipeline, cache, providers.
//  ContentView only calls `configure(modelContext:)`; no longer knows InlineCompletionService details.
//

import SwiftData

enum CommandIntelligenceAssembly {
    @MainActor static func configure(modelContext: ModelContext) {
        // Existing stores (keep for now)
        AIProviderStore.shared.setModelContext(modelContext)
        InlineCompletionService.shared.attachModelContext(modelContext)

        // New pipeline cache — will be per-pane in future, but global for now for parity
        // PaneContainerBridge creates per-pane pipelines and attaches modelContext there.
        // This global attach ensures any shared pipeline (future) also has persistence.
    }
}
