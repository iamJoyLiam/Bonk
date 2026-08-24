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
    @State private var hoveredID: UUID?

    private let persistence = WorkspacePersistenceManager.shared

    var body: some View {
        VStack(spacing: 0) {
            PanelHeaderView(
                icon: "square.stack.3d.up",
                title: i18n.t(.workspaces),
                count: workspaces.count,
                countLabel: i18n.tr(.workspaceCount, args: workspaces.count)
            )
            Divider()
            if workspaces.isEmpty {
                PanelEmptyView(
                    icon: "square.stack.3d.up",
                    title: i18n.t(.noWorkspaces),
                    hint: i18n.t(.noWorkspacesHint)
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: AppStyle.spacingS) {
                        ForEach(workspaces) { ws in
                            workspaceCard(ws)
                        }
                    }
                    .padding(AppStyle.spacingL)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
            Divider()
            footerSection
        }
        .frame(minWidth: 520, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadWorkspaces() }
        .alert(i18n.t(.delete), isPresented: .init(
            get: { workspaceToDelete != nil },
            set: { if !$0 { workspaceToDelete = nil } }
        )) {
            Button(i18n.t(.cancel), role: .cancel) { workspaceToDelete = nil }
            Button(i18n.t(.delete), role: .destructive) {
                if let ws = workspaceToDelete { deleteWorkspace(ws) }
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
                workspaceToRename = nil; renameName = ""
            }
            Button(i18n.t(.save)) {
                if let ws = workspaceToRename, !renameName.isEmpty {
                    renameWorkspace(ws, to: renameName)
                }
                workspaceToRename = nil; renameName = ""
            }
        } message: {
            Text(i18n.t(.enterNewName))
        }
        .sheet(isPresented: $showSaveSheet) { saveWorkspaceSheet }
    }

    // MARK: - Card

    private func workspaceCard(_ workspace: WorkspacePersistenceManager.WorkspaceData) -> some View {
        let isHovered = hoveredID == workspace.id
        return HStack(spacing: AppStyle.spacingL) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: AppStyle.fontMedium))
                .foregroundStyle(.blue)
                .frame(width: AppStyle.buttonLarge, height: AppStyle.buttonLarge)
            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.name)
                    .font(.system(size: AppStyle.fontRegular, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: AppStyle.spacingS) {
                    Label(i18n.tr(.tabsCount, args: workspace.tabs.count), systemImage: "sidebar.left")
                    Text("•").foregroundStyle(.tertiary)
                    Text(workspace.updatedAt, style: .relative)
                    Text(i18n.t(.ago))
                }
                .font(.system(size: AppStyle.fontCaption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: AppStyle.spacingM)
            HStack(spacing: AppStyle.spacingS) {
                Button { loadWorkspace(workspace) } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: AppStyle.fontSmall, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: AppStyle.buttonMedium, height: AppStyle.buttonMedium)
                        .background(Circle().fill(Color.accentColor))
                        .shadow(color: Color.accentColor.opacity(isHovered ? 0.25 : 0), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .help(i18n.t(.loadWorkspace))

                Menu {
                    Button {
                        workspaceToRename = workspace
                        renameName = workspace.name
                    } label: { Label(i18n.t(.rename), systemImage: "pencil") }
                    Divider()
                    Button(role: .destructive) { workspaceToDelete = workspace } label: {
                        Label(i18n.t(.delete), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: AppStyle.fontSmall, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: AppStyle.buttonMedium, height: AppStyle.buttonMedium)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(AppStyle.opacityStroke), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: AppStyle.iconDisplay)
            }
        }
        .padding(.horizontal, AppStyle.spacingL)
        .padding(.vertical, AppStyle.spacingML)
        .background(
            RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: Color.black.opacity(isHovered ? 0.06 : 0.03), radius: isHovered ? 8 : 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppStyle.cornerRadiusMedium, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovered ? 0.08 : 0.04), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { hoveredID = hovering ? workspace.id : nil }
        }
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
        .padding(.horizontal, AppStyle.spacingXL)
        .padding(.vertical, AppStyle.spacingL)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Save Sheet

    private var saveWorkspaceSheet: some View {
        NavigationStack {
            Form {
                Section(i18n.t(.workspaceName)) {
                    TextField(i18n.t(.workspaceName), text: $newWorkspaceName)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle(i18n.t(.saveWorkspace))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(i18n.t(.cancel)) { showSaveSheet = false; newWorkspaceName = "" }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(i18n.t(.save)) {
                        saveWorkspace(); showSaveSheet = false; newWorkspaceName = ""
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
        if let workspace = persistence.saveWorkspace(name: name, sessionManager: sessionManager) {
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
