//
//  WorkspaceListView.swift
//  Bonk
//
//  Workspace management UI.
//

import SwiftData
import SwiftUI

/// List view for managing workspaces.
struct WorkspaceListView: View {
    @Environment(I18n.self) private var i18n
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Workspace.createdAt, order: .reverse)
    private var workspaces: [Workspace]

    @Bindable var sessionManager: SessionManager

    @State private var showSaveSheet = false
    @State private var newWorkspaceName = ""
    @State private var workspaceToDelete: Workspace?
    @State private var workspaceToRename: Workspace?
    @State private var renameName = ""

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
                Text("Delete workspace '\(ws.name)'?")
            }
        }
        .alert("Rename Workspace", isPresented: .init(
            get: { workspaceToRename != nil },
            set: { if !$0 { workspaceToRename = nil } }
        )) {
            TextField("Workspace name", text: $renameName)
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
            Text("Enter a new name for this workspace:")
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
            Text("Workspaces")
                .font(.headline)
            Spacer()
            Text("\(workspaces.count) saved")
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
            Text("No Workspaces")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Save your current tab layout as a workspace to quickly restore it later.")
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

    private func workspaceRow(_ workspace: Workspace) -> some View {
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
                    Label("\(workspace.tabs.count) tabs", systemImage: "sidebar.left")
                    Text("•")
                    Text(workspace.updatedAt, style: .relative)
                    Text("ago")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Actions
            HStack(spacing: 8) {
                Button {
                    loadWorkspace(workspace)
                } label: {
                    Label("Open", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

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
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
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

            Button("Save Current as Workspace") {
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
            Text("Save Workspace")
                .font(.headline)

            TextField("Workspace name", text: $newWorkspaceName)
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

    private func saveWorkspace() {
        let name = newWorkspaceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        _ = WorkspacePersistenceManager.shared.saveWorkspace(
            name: name,
            sessionManager: sessionManager,
            modelContext: modelContext
        )
    }

    private func loadWorkspace(_ workspace: Workspace) {
        // Load host items for workspace tabs
        var hostStore: [UUID: HostItem] = [:]
        let descriptor = FetchDescriptor<HostItem>()
        if let hosts = try? modelContext.fetch(descriptor) {
            for host in hosts {
                hostStore[host.id] = host
            }
        }

        WorkspacePersistenceManager.shared.loadWorkspace(
            workspace,
            sessionManager: sessionManager,
            hostStore: hostStore
        )
        dismiss()
    }

    private func renameWorkspace(_ workspace: Workspace, to newName: String) {
        WorkspacePersistenceManager.shared.renameWorkspace(workspace, to: newName, modelContext: modelContext)
    }

    private func deleteWorkspace(_ workspace: Workspace) {
        WorkspacePersistenceManager.shared.deleteWorkspace(workspace, modelContext: modelContext)
    }
}

// MARK: - Preview

#Preview {
    WorkspaceListView(sessionManager: SessionManager())
        .environment(I18n())
}
