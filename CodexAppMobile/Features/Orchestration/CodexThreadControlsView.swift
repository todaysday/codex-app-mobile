import SwiftUI

struct CodexThreadControlsView: View {
    @ObservedObject var client: AppServerClient
    let threadID: String
    let modelID: String?
    let fallbackTitle: String
    let onHistoryChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var history: CodexThreadDetail?
    @State private var goalLoaded = false
    @State private var isRefreshing = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var nameDraft = ""
    @State private var selectedRevertTurnID = ""
    @State private var showsRename = false
    @State private var confirmsClear = false
    @State private var confirmsCompact = false
    @State private var confirmsRevert = false

    private var record: RemoteThreadRecord? { client.threadRecordsByID[threadID] }
    private var goal: CodexThreadGoal? { client.threadGoalsByID[threadID] }
    private var isConnected: Bool { client.state == .connected }
    private var isCompacting: Bool { client.compactingThreads.contains(threadID) }
    private var canMutate: Bool {
        isConnected && !isWorking && !isRefreshing && CodexThreadControlPolicy.acceptsDirectInput(record?.canAcceptDirectInput)
    }
    private var canCompact: Bool {
        canMutate && !unsupported("thread/compact/start") && CodexThreadControlPolicy.canCompact(
            record: record, activeTurnID: client.activeTurnID(for: threadID), isCompacting: isCompacting)
    }
    private var canRevert: Bool {
        canMutate && !unsupported("thread/revert") && CodexThreadControlPolicy.canRevert(
            record: record, activeTurnID: client.activeTurnID(for: threadID), isCompacting: isCompacting)
    }
    private var selectedRevertTurn: CodexTurn? { history?.turns.first(where: { $0.id == selectedRevertTurnID }) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(client.threadNamesByID[threadID] ?? record?.name ?? fallbackTitle).font(.headline)
                    Text(CodexThreadControlPolicy.statusTitle(record?.status)).foregroundStyle(.secondary)
                    if record?.canAcceptDirectInput == false {
                        Label("This thread does not accept direct input.", systemImage: "eye")
                    }
                    if !isConnected { Text("Reconnect to use server controls.").foregroundStyle(.secondary) }
                    if isRefreshing || isWorking { ProgressView(isWorking ? "Applying change…" : "Refreshing…") }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                }
                goalSection
                actionsSection
                snapshotsSection
                if let descriptor = client.availableModels.first(where: { $0.model == modelID }) {
                    Section("Model") {
                        NavigationLink(descriptor.displayName) { CodexModelDetailsView(model: descriptor) }
                    }
                }
            }
            .navigationTitle("Thread Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh thread controls").disabled(isRefreshing || isWorking || !isConnected)
                }
            }
            .task(id: threadID) { await refresh() }
            .alert("Rename Thread", isPresented: $showsRename) {
                TextField("Thread name", text: $nameDraft)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    runAction {
                        try await client.threadRename(threadID: threadID, name: name)
                        return "Thread renamed."
                    }
                }.disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canMutate)
            }
            .confirmationDialog("Clear this thread's goal?", isPresented: $confirmsClear, titleVisibility: .visible) {
                Button("Clear Goal", role: .destructive) {
                    runAction {
                        let cleared = try await client.threadGoalClear(threadID: threadID)
                        return cleared ? "Goal cleared." : "The server reported no remaining goal to clear."
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: { Text("This removes the goal from this thread. Its conversation remains available.") }
            .confirmationDialog("Compact this thread?", isPresented: $confirmsCompact, titleVisibility: .visible) {
                Button("Request Compaction") {
                    guard canCompact else { return }
                    runAction {
                        try await client.threadCompact(threadID: threadID)
                        return "Compaction requested. Wait for the server to finish, then refresh the thread."
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: { Text("The server will summarize this idle thread's context. Completion is reported separately.") }
            .confirmationDialog("Remove conversation history?", isPresented: $confirmsRevert, titleVisibility: .visible) {
                Button("Remove Selected Turn and Later History", role: .destructive) {
                    guard canRevert, let turn = selectedRevertTurn else { return }
                    runAction {
                        history = try await client.threadRevert(threadID: threadID, beforeTurnID: turn.id)
                        selectedRevertTurnID = history?.turns.last?.id ?? ""
                        onHistoryChanged()
                        return "Conversation history refreshed. File changes were not reverted."
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Remove “\(selectedRevertTurn.map(CodexThreadControlPolicy.turnTitle) ?? "selected turn")” and all later conversation history. Changes to files are NOT reverted.")
            }
        }
    }

    private var goalSection: some View {
        Section("Goal") {
            if unsupported("thread/goal/get") {
                Text("Goals are unavailable on this server connection. Other thread features remain available.")
                    .foregroundStyle(.secondary)
            } else {
                if let goal {
                    Text(goal.objective).textSelection(.enabled)
                    LabeledContent("Status", value: goal.statusTitle)
                    LabeledContent("Tokens used", value: goal.tokensUsed.formatted())
                    LabeledContent("Token budget", value: goal.tokenBudget.map { $0.formatted() } ?? "No limit")
                    LabeledContent("Time used", value: "\(goal.timeUsedSeconds.formatted()) seconds")
                    if canMutate && !unsupported("thread/goal/set") {
                        if goal.status == "active" {
                            Button("Pause Goal") { changeGoalStatus("paused") }
                        } else {
                            Button("Resume Goal") { changeGoalStatus("active") }
                        }
                        if goal.status != "complete" {
                            Button("Mark Goal Complete") { changeGoalStatus("complete") }
                        }
                    }
                } else if goalLoaded {
                    Text("This thread has no goal.").foregroundStyle(.secondary)
                } else if !isRefreshing {
                    Text("The goal has not been loaded. Refresh to retry.").foregroundStyle(.secondary)
                }
                NavigationLink(goal == nil ? "Add Goal" : "Edit Goal") {
                    CodexGoalEditorView(client: client, threadID: threadID, goal: goal)
                }
                .disabled(!goalLoaded || !canMutate || unsupported("thread/goal/set"))
                if goal != nil {
                    Button("Clear Goal", role: .destructive) { confirmsClear = true }
                        .disabled(!canMutate || unsupported("thread/goal/clear"))
                }
                if unsupported("thread/goal/set") || unsupported("thread/goal/clear") {
                    Text("This server cannot perform one or more goal changes.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actionsSection: some View {
        Section("Thread Actions") {
            Button("Rename Thread") {
                nameDraft = client.threadNamesByID[threadID] ?? record?.name ?? fallbackTitle
                showsRename = true
            }.disabled(!canMutate || unsupported("thread/name/set"))
            Button("Compact Context") { confirmsCompact = true }.disabled(!canCompact)
            if isCompacting { Label("Compaction is in progress.", systemImage: "hourglass") }
            if let turns = history?.turns, !turns.isEmpty {
                Picker("Remove history from", selection: $selectedRevertTurnID) {
                    ForEach(turns) { turn in
                        Text(CodexThreadControlPolicy.turnTitle(turn)).tag(turn.id)
                    }
                }
                .disabled(!canRevert)
                Button("Revert Conversation History…", role: .destructive) { confirmsRevert = true }
                    .disabled(!canRevert || selectedRevertTurn == nil)
            }
            Text("Compaction requires an idle thread. History revert also requires a loaded, persistent thread with paginated history. It does not undo file changes.")
                .font(.caption).foregroundStyle(.secondary)
            if ["thread/name/set", "thread/compact/start", "thread/revert"].contains(where: unsupported) {
                Text("Some actions are unavailable on this server connection.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var snapshotsSection: some View {
        Section("Current Turn") {
            NavigationLink {
                CodexTurnSnapshotView(client: client, threadID: threadID, kind: .plan)
            } label: {
                Label("Plan", systemImage: "list.bullet.clipboard")
            }
            NavigationLink {
                CodexTurnSnapshotView(client: client, threadID: threadID, kind: .diff)
            } label: {
                Label("Server Changes", systemImage: "doc.text.magnifyingglass")
            }
            NavigationLink {
                CodexThreadUsageView(client: client, threadID: threadID)
            } label: {
                Label("Token Usage", systemImage: "chart.bar")
            }
            Text("These are the server's latest plan and aggregate diff for this thread. The Git menu shows the working tree separately.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func unsupported(_ method: String) -> Bool { client.unsupportedOfficialMethods.contains(method) }

    private func changeGoalStatus(_ status: String) {
        runAction {
            _ = try await client.threadGoalSet(threadID: threadID, status: status)
            return nil
        }
    }

    @MainActor
    private func refresh() async {
        guard !isRefreshing, !isWorking, isConnected else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }
        do {
            history = try await client.threadRead(threadID: threadID)
            if selectedRevertTurn == nil { selectedRevertTurnID = history?.turns.last?.id ?? "" }
        } catch { errorMessage = client.userFacingMessage(for: error) }
        guard !Task.isCancelled else { return }
        if !unsupported("thread/goal/get") {
            do {
                _ = try await client.threadGoalGet(threadID: threadID)
                goalLoaded = true
            } catch { errorMessage = client.userFacingMessage(for: error) }
        }
    }

    private func runAction(_ action: @escaping @MainActor () async throws -> String?) {
        guard canMutate else { return }
        isWorking = true
        errorMessage = nil
        notice = nil
        Task { @MainActor in
            defer { isWorking = false }
            do { notice = try await action() }
            catch { errorMessage = client.userFacingMessage(for: error) }
        }
    }
}
