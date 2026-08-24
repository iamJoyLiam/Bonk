//
//  WorkspaceListView.swift
//  Bonk
//
//  Workspace management UI using plist persistence.
//

import SwiftData
import SwiftUI

/// List view for managing workspaces — plain list (not cards), matches screenshot.
struct WorkspaceListView: View {
    @Environment(I18n.self) private var i18n
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Bindable var sessionManager: SessionManager

    @State private var workspaces: [WorkspacePersistenceManager.WorkspaceData] = []
    @State private var showSaveSheet = false
    @State private var newWorkspaceName = ""
    @State private var newWorkspaceIsTemplate = false
    @State private var workspaceToDelete: WorkspacePersistenceManager.WorkspaceData?
    @State private var workspaceToRename: WorkspacePersistenceManager.WorkspaceData?
    @State private var renameName = ""

    private let persistence = WorkspacePersistenceManager.shared

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            if workspaces.isEmpty {
                emptyStateView
            } else {
                workspaceList
            }
            Divider()
            footerSection
        }
        .frame(minWidth: AppStyle.serialPortWidth, minHeight: AppStyle.newConnectionHeight)
        .onAppear { loadWorkspaces() }
        .alert(i18n.t(.delete), isPresented: .init(
            get: { workspaceToDelete != nil },
            set: { if !$0 { workspaceToDelete = nil } }
        )) {
            Button(i18n.t(.cancel), role: .cancel) { workspaceToDelete = nil }
            Button(i18n.t(.delete), role: .destructive) {
                if let workspace = workspaceToDelete { deleteWorkspace(workspace) }
            }
        } message: {
            if let workspace = workspaceToDelete {
                Text(i18n.tr(.deleteWorkspaceConfirm, args: workspace.name))
            }
        }
        .alert(i18n.t(.renameWorkspace), isPresented: .init(
            get: { workspaceToRename != nil },
            set: { if !$0 { workspaceToRename = nil } }
        )) {
            TextField(i18n.t(.workspaceName), text: $renameName)
            Button(i18n.t(.cancel), role: .cancel) {
                workspaceToRename = nil; renameName = ""
            }
            Button(i18n.t(.save)) {
                if let workspace = workspaceToRename, !renameName.isEmpty {
                    renameWorkspace(workspace, to: renameName)
                }
                workspaceToRename = nil; renameName = ""
            }
        } message: {
            Text(i18n.t(.enterNewName))
        }
        .sheet(isPresented: $showSaveSheet) { saveWorkspaceSheet }
    }

    // MARK: - Header — exactly as screenshot: blue icon + headline, right count caption

    private var headerSection: some View {
        HStack {
            Image(systemName: "square.stack.3d.up")
                .font(.title2)
                .foregroundStyle(.blue)
            Text(i18n.t(.workspaces))
                .font(.headline)
            Spacer()
            Text(i18n.tr(.workspaceCount, args: workspaces.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Empty

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: AppStyle.fontDisplay))
                .foregroundStyle(.tertiary)
            Text(i18n.t(.noWorkspaces))
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(i18n.t(.noWorkspacesHint))
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: AppStyle.panelWidthSmall)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List — plain rows + dividers, no cards

    private var workspaceList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(workspaces) { workspace in
                    workspaceRow(workspace)
                    if workspace.id != workspaces.last?.id {
                        Divider()
                            .padding(.leading, AppStyle.spacingSidebar)
                    }
                }
            }
        }
    }

    private func workspaceRow(_ workspace: WorkspacePersistenceManager.WorkspaceData) -> some View {
        HStack(spacing: 12) {
            Image(systemName: workspace.isTemplate == true ? "square.stack.3d.up.badge.a.fill" : "square.stack.3d.up.fill")
                .foregroundStyle(workspace.isTemplate == true ? .orange : .blue)
                .frame(width: AppStyle.buttonMedium)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(workspace.name)
                        .font(.headline)
                        .lineLimit(1)
                    if workspace.isTemplate == true {
                        Text(i18n.t(.template)).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange.opacity(0.15)).cornerRadius(4)
                    }
                }
                HStack(spacing: 8) {
                    Label(i18n.tr(.tabsCount, args: workspace.tabs.count), systemImage: "sidebar.left")
                    Text("•").foregroundStyle(.tertiary)
                    Text(workspace.updatedAt, style: .relative)
                    Text(i18n.t(.ago))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 4) {
                Button { loadWorkspace(workspace) } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: AppStyle.fontSubtitle))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help(i18n.t(.loadWorkspace))

                Menu {
                    Button {
                        workspaceToRename = workspace
                        renameName = workspace.name
                    } label: { Label(i18n.t(.rename), systemImage: "pencil") }
                    Divider()
                    Button(role: .destructive) { workspaceToDelete = workspace } label: { Label(i18n.t(.delete), systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: AppStyle.iconDisplay)
            }
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingML)
        .contentShape(Rectangle())
        .onTapGesture { loadWorkspace(workspace) }
        .contextMenu {
            Button { loadWorkspace(workspace) } label: { Label(i18n.t(.loadWorkspace), systemImage: "arrow.right.circle") }
            Button { workspaceToRename = workspace; renameName = workspace.name } label: { Label(i18n.t(.rename), systemImage: "pencil") }
            Divider()
            Button(role: .destructive) { workspaceToDelete = workspace } label: { Label(i18n.t(.delete), systemImage: "trash") }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(i18n.t(.cancel)) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(i18n.t(.saveCurrentAsWorkspace)) { showSaveSheet = true }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    // MARK: - Save Sheet

    private var saveWorkspaceSheet: some View {
        NavigationStack {
            Form {
                Section(i18n.t(.workspaceName)) {
                    TextField(i18n.t(.workspaceName), text: $newWorkspaceName)
                }
                Section {
                    Toggle(i18n.t(.saveAsTemplate), isOn: $newWorkspaceIsTemplate)
                    Text(i18n.t(.templateDescription)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle(i18n.t(.saveWorkspace))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(i18n.t(.cancel)) { showSaveSheet = false; newWorkspaceName = ""; newWorkspaceIsTemplate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(i18n.t(.save)) {
                        saveWorkspace(); showSaveSheet = false; newWorkspaceName = ""; newWorkspaceIsTemplate = false
                    }
                    .disabled(newWorkspaceName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: AppStyle.quickConnectWidth)
        .presentationDetents([.medium])
    }

    // MARK: - Actions

    private func loadWorkspaces() {
        workspaces = persistence.loadAllWorkspaces()
    }

    private func saveWorkspace() {
        let name = newWorkspaceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let workspace = persistence.saveWorkspace(name: name, sessionManager: sessionManager, isTemplate: newWorkspaceIsTemplate) {
            if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
                workspaces[index] = workspace
            } else {
                workspaces.insert(workspace, at: 0)
            }
        }
    }

    private func loadWorkspace(_ workspace: WorkspacePersistenceManager.WorkspaceData) {
        Task {
            await persistence.restoreWorkspace(workspace, sessionManager: sessionManager, modelContext: modelContext)
            dismiss()
        }
    }

    private func renameWorkspace(_ workspace: WorkspacePersistenceManager.WorkspaceData, to newName: String) {
        persistence.renameWorkspace(id: workspace.id, to: newName)
        loadWorkspaces()
    }

    private func deleteWorkspace(_ workspace: WorkspacePersistenceManager.WorkspaceData) {
        persistence.deleteWorkspace(id: workspace.id)
        loadWorkspaces()
    }
}

// MARK: - Preview

#Preview {
    WorkspaceListView(sessionManager: SessionManager())
        .environment(I18n())
}
