//
//  WorkspaceListView.swift
//  Bonk
//
//  Workspace management UI using plist persistence.
//

import SwiftData
import SwiftUI

/// List view for managing workspaces.
struct WorkspaceListView: View {
    @Environment(I18n.self) private var i18n
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Bindable var sessionManager: SessionManager

    @State private var workspaces: [WorkspacePersistenceManager.WorkspaceData] = []
    @State private var showSaveSheet = false
    @State private var newWorkspaceName = ""
    @State private var workspaceToDelete: WorkspacePersistenceManager.WorkspaceData?
    @State private var workspaceToRename: WorkspacePersistenceManager.WorkspaceData?
    @State private var renameName = ""

    private let persistence = WorkspacePersistenceManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            // Workspace list
            if workspaces.isEmpty {
                emptyStateView
            } else {
                workspaceList
            }

            Divider()

            // Footer
            footerSection
        }
        .frame(minWidth: 450, minHeight: 350)
        .onAppear {
            loadWorkspaces()
        }
        .alert(i18n.t(.delete), isPresented: .init(
            get: { workspaceToDelete != nil },
            set: { if !$0 { workspaceToDelete = nil } }
        )) {
            Button(i18n.t(.cancel), role: .cancel) { workspaceToDelete = nil }
            Button(i18n.t(.delete), role: .destructive) {
                if let ws = workspaceToDelete {
                    deleteWorkspace(ws)
                }
            }
        } message: {
            if let ws = workspaceToDelete {
                Text(i18n.tr(.deleteWorkspaceConfirm, args: ws.name))
            }
        }
        .alert(i18n.t(.renameWorkspace), isPresented: .init(
            get: { workspaceToRename != nil },
            set: { if !$0 { workspaceToRename = nil } }
        )) {
            TextField(i18n.t(.workspaceName), text: $renameName)
            Button(i18n.t(.cancel), role: .cancel) {
                workspaceToRename = nil
                renameName = ""
            }
            Button(i18n.t(.save)) {
                if let ws = workspaceToRename, !renameName.isEmpty {
                    renameWorkspace(ws, to: renameName)
                }
                workspaceToRename = nil
                renameName = ""
            }
        } message: {
            Text(i18n.t(.enterNewName))
        }
        .sheet(isPresented: $showSaveSheet) {
            saveWorkspaceSheet
        }
    }

    // MARK: - Header

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

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(i18n.t(.noWorkspaces))
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(i18n.t(.noWorkspacesHint))
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Workspace List

    private var workspaceList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(workspaces) { workspace in
                    workspaceRow(workspace)

                    if workspace.id != workspaces.last?.id {
                        Divider()
                            .padding(.leading, 44)
                    }
                }
            }
        }
    }

    private func workspaceRow(_ workspace: WorkspacePersistenceManager.WorkspaceData) -> some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(.blue)
                .frame(width: 28)

            // Info
            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.name)
                    .font(.headline)
                HStack(spacing: 8) {
                    Label(i18n.tr(.tabsCount, args: workspace.tabs.count), systemImage: "sidebar.left")
                    Text("•")
                    Text(workspace.updatedAt, style: .relative)
                    Text(i18n.t(.ago))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Actions
            HStack(spacing: 4) {
                // 打开按钮 - 直接点击打开
                Button {
                    loadWorkspace(workspace)
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help(i18n.t(.loadWorkspace))

                // "..." 菜单 - 重命名、删除
                Menu {
                    Button {
                        workspaceToRename = workspace
                        renameName = workspace.name
                    } label: {
                        Label(i18n.t(.rename), systemImage: "pencil")
                    }

                    Divider()

                    Button(role: .destructive) {
                        workspaceToDelete = workspace
                    } label: {
                        Label(i18n.t(.delete), systemImage: "trash")
                    }
                } label: {
                    EmptyView()
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            loadWorkspace(workspace)
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(i18n.t(.cancel)) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(i18n.t(.saveCurrentAsWorkspace)) {
                showSaveSheet = true
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    // MARK: - Save Sheet

    private var saveWorkspaceSheet: some View {
        VStack(spacing: 16) {
            Text(i18n.t(.saveWorkspace))
                .font(.headline)

            TextField(i18n.t(.workspaceName), text: $newWorkspaceName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            HStack {
                Button(i18n.t(.cancel)) {
                    showSaveSheet = false
                    newWorkspaceName = ""
                }
                .keyboardShortcut(.cancelAction)

                Button(i18n.t(.save)) {
                    saveWorkspace()
                    showSaveSheet = false
                    newWorkspaceName = ""
                }
                .disabled(newWorkspaceName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400)
    }

    // MARK: - Actions

    private func loadWorkspaces() {
        workspaces = persistence.loadAllWorkspaces()
    }

    private func saveWorkspace() {
        let name = newWorkspaceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        if let workspace = persistence.saveWorkspace(name: name, sessionManager: sessionManager) {
            // Check if we updated an existing workspace or created a new one
            if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
                workspaces[index] = workspace
            } else {
                workspaces.insert(workspace, at: 0)
            }
        }
    }

    private func loadWorkspace(_ workspace: WorkspacePersistenceManager.WorkspaceData) {
        persistence.restoreWorkspace(workspace, sessionManager: sessionManager, modelContext: modelContext)
        dismiss()
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
