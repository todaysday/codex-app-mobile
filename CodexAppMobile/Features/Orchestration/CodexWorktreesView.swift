import SwiftUI

struct CodexWorktreesView: View {
    @ObservedObject var client: AppServerClient
    let hostID: UUID
    let workspace: ProjectWorkspace
    let onOpen: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var worktrees: [CodexGitWorktree] = []
    @State private var isLoading = false
    @State private var isMutating = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var isCreating = false
    @State private var pendingRemoval: WorktreeSelection?
    @State private var loadedGeneration: Int?
    @State private var creationGeneration: Int?
    @State private var loadID = UUID()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(workspace.remotePath).font(.caption.monospaced()).textSelection(.enabled)
                } footer: {
                    Text("Create a branch and worktree, or open an existing worktree as a workspace. Git runs on this host with its configured permissions.")
                }
                if !client.isConnected(to: hostID) {
                    Text("Connect to this host to manage worktrees.").foregroundStyle(.secondary)
                } else {
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
                    if let statusMessage { Text(statusMessage).foregroundStyle(.secondary) }
                    if isLoading || isMutating { ProgressView(isMutating ? "Updating worktree…" : "Loading worktrees…") }
                    if isCurrentSnapshot {
                        Section("Worktrees") {
                            ForEach(worktrees) { worktree in
                                worktreeRow(worktree)
                            }
                        }
                    }
                    if !isLoading, worktrees.isEmpty, errorMessage == nil {
                        Text("No worktrees found.").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Worktrees")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(isMutating) }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { Task { await reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(isLoading || isMutating || !client.isConnected(to: hostID))
                    Button {
                        guard isCurrentSnapshot else { return }
                        creationGeneration = loadedGeneration
                        isCreating = true
                    } label: { Label("Create worktree", systemImage: "plus") }
                        .disabled(isLoading || isMutating || !isCurrentSnapshot)
                }
            }
            .sheet(isPresented: $isCreating) {
                if let creationGeneration {
                    CodexCreateWorktreeView(client: client, hostID: hostID, workspace: workspace, expectedGeneration: creationGeneration) {
                        statusMessage = "Worktree created. Choose Open to switch to it."
                        Task { await reload() }
                    }
                }
            }
            .confirmationDialog("Remove this worktree?", isPresented: removalPresented, presenting: pendingRemoval) { selection in
                Button("Remove worktree", role: .destructive) { Task { await remove(selection) } }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: { selection in
                Text("\(selection.worktree.path)\n\nThe directory will be removed after checking for changes. Its branch and saved workspace record will be kept.")
            }
            .task(id: "\(client.connectionGeneration):\(client.state.rawValue)") { await reload() }
            .refreshable { if !isMutating { await reload() } }
            .interactiveDismissDisabled(isMutating)
        }
    }

    private var removalPresented: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private var isCurrentSnapshot: Bool {
        loadedGeneration == client.connectionGeneration && client.isConnected(to: hostID)
    }

    private struct WorktreeSelection {
        let worktree: CodexGitWorktree
        let generation: Int
    }

    private func worktreeRow(_ worktree: CodexGitWorktree) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(CodexWorkspacePath.name(worktree.path), systemImage: "arrow.triangle.branch")
                    .font(.headline)
                if worktree.isMain { Text("Main").font(.caption).foregroundStyle(.secondary) }
                if worktree.isCurrent { Text("Current").font(.caption).foregroundStyle(.secondary) }
            }
            Text(worktree.path).font(.caption.monospaced()).textSelection(.enabled)
            if let branch = worktree.branch {
                Text(branch.hasPrefix("refs/heads/") ? String(branch.dropFirst(11)) : branch).font(.subheadline)
            } else if worktree.isDetached {
                Text("Detached HEAD \(worktree.head.map { String($0.prefix(12)) } ?? "")").font(.subheadline)
            } else if worktree.isBare {
                Text("Bare repository").font(.subheadline)
            }
            if let locked = worktree.lockedReason {
                Label(locked.isEmpty ? "Locked" : "Locked: \(locked)", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
            }
            if let prunable = worktree.prunableReason {
                Text(prunable.isEmpty ? "Prunable" : "Prunable: \(prunable)").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open") {
                    guard isCurrentSnapshot, !isLoading, !isMutating else { return }
                    onOpen(worktree.path)
                    dismiss()
                }
                .disabled(!worktree.canOpen || isLoading || isMutating || !isCurrentSnapshot)
                Spacer()
                Button("Remove", role: .destructive) {
                    guard isCurrentSnapshot, let loadedGeneration else { return }
                    pendingRemoval = WorktreeSelection(worktree: worktree, generation: loadedGeneration)
                }
                    .disabled(worktree.removalBlockReason != nil || isLoading || isMutating || !isCurrentSnapshot)
            }
            .buttonStyle(.borderless)
            if let reason = worktree.removalBlockReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @MainActor private func reload() async {
        let token = UUID()
        let generation = client.connectionGeneration
        loadID = token
        loadedGeneration = nil
        worktrees = []
        errorMessage = nil
        pendingRemoval = nil
        isLoading = true
        defer { if loadID == token { isLoading = false } }
        guard client.isConnected(to: hostID) else { return }
        do {
            let result = try await client.workspaceWorktrees(hostID: hostID, workspacePath: workspace.remotePath)
            guard loadID == token, !Task.isCancelled,
                  generation == client.connectionGeneration, client.isConnected(to: hostID) else { return }
            worktrees = result
            loadedGeneration = generation
        } catch {
            guard loadID == token, !Task.isCancelled,
                  generation == client.connectionGeneration, client.isConnected(to: hostID) else { return }
            errorMessage = error.localizedDescription
        }
    }

    @MainActor private func remove(_ selection: WorktreeSelection) async {
        guard !isMutating else { return }
        pendingRemoval = nil
        isMutating = true
        errorMessage = nil
        statusMessage = nil
        defer { isMutating = false }
        do {
            try await client.workspaceRemoveWorktree(
                hostID: hostID, workspacePath: workspace.remotePath, targetPath: selection.worktree.path,
                expectedGeneration: selection.generation
            )
            guard selection.generation == client.connectionGeneration, client.isConnected(to: hostID) else { return }
            statusMessage = "Worktree removed. Its branch and saved workspace record were kept."
            await reload()
        } catch {
            errorMessage = "\(error.localizedDescription)\nRefresh the list before trying again."
        }
    }
}

private struct CodexCreateWorktreeView: View {
    @ObservedObject var client: AppServerClient
    let hostID: UUID
    let workspace: ProjectWorkspace
    let expectedGeneration: Int
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var branch = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Absolute directory path", text: $destination)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("New branch name", text: $branch)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("New worktree")
                } footer: {
                    Text("Creates a new branch from this workspace's current HEAD. The destination must be available and writable under the host's configured permissions.")
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
                if expectedGeneration != client.connectionGeneration {
                    Text("The connection changed. Close this form and reopen it after refreshing the worktree list.").foregroundStyle(.secondary)
                }
                if isSaving { ProgressView("Creating worktree…") }
            }
            .navigationTitle("Create worktree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(isSaving || destination.isEmpty || branch.isEmpty || !client.isConnected(to: hostID)
                                  || expectedGeneration != client.connectionGeneration)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @MainActor private func create() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await client.workspaceCreateWorktree(
                hostID: hostID, workspacePath: workspace.remotePath, destination: destination, branch: branch,
                expectedGeneration: expectedGeneration
            )
            guard expectedGeneration == client.connectionGeneration, client.isConnected(to: hostID) else { return }
            onCreated()
            dismiss()
        } catch {
            errorMessage = "\(error.localizedDescription)\nRefresh the worktree list before retrying after a connection failure."
        }
    }
}
