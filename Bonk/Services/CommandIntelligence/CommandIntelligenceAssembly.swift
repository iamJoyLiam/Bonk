//  CommandIntelligenceAssembly.swift
//  Bonk
//
//  Composition root for Command Intelligence — configures workspace, pipeline, cache, providers.
//  ContentView only calls `configure(modelContext:)`; no longer knows InlineCompletionService details.
//

import SwiftData

enum CommandIntelligenceAssembly {
    @MainActor static func configure(modelContext: ModelContext) {
        AIProviderStore.shared.setModelContext(modelContext)
        // Pipeline persistence is per-pane via PaneContainerBridge.inlinePipeline.attachModelContext
    }
}
