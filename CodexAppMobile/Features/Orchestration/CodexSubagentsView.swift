import SwiftUI

struct CodexSubagentsView: View {
    @ObservedObject var client: AppServerClient
    let rootThreadID: String
    let rootTitle: String
    @Environment(\.dismiss) private var dismiss
    @State private var threads: [RemoteThreadRecord] = []
    @State private var path: [String] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    private var rows: [CodexAgentTreeRow] { CodexAgentTree.rows(rootID: rootThreadID, threads: threads) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Text(rootTitle).font(.headline)
                    Text("Read existing agents and their messages. Opening a thread does not start a turn or change the parent.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let root = client.threadRecordsByID[rootThreadID] {
                        Text(CodexThreadControlPolicy.statusTitle(root.status)).font(.caption)
                    }
                    if client.state != .connected { Text("Reconnect to read subagents.").foregroundStyle(.secondary) }
                }
                if isLoading { ProgressView("Loading subagents…") }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                if client.unsupportedOfficialMethods.contains("thread/list.relationships") {
                    Text("This server does not support subagent relationship queries. Normal thread history remains available.")
                        .foregroundStyle(.secondary)
                } else if hasLoaded && rows.isEmpty {
                    Text("No subagents were returned for this thread.").foregroundStyle(.secondary)
                }
                Section("Subagents") {
                    ForEach(rows) { row in
                        NavigationLink(value: row.id) {
                            CodexSubagentRow(record: client.threadRecordsByID[row.id] ?? row.thread,
                                             hasMissingParent: row.hasMissingParent)
                                .padding(.leading, CGFloat(min(row.depth, 8)) * 12)
                        }
                    }
                }
            }
            .navigationTitle("Subagents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh subagents").disabled(isLoading || client.state != .connected)
                }
            }
            .navigationDestination(for: String.self) { threadID in
                CodexSubagentThreadView(client: client, threadID: threadID, rootThreadID: rootThreadID,
                                         fallback: threads.first(where: { $0.id == threadID }),
                                         openThread: openThread, returnToWorkbench: { dismiss() })
            }
            .task(id: rootThreadID) { await refresh() }
            .refreshable { await refresh() }
        }
    }

    private func openThread(_ threadID: String) {
        path = CodexSubagentNavigation.path(current: path, opening: threadID, rootID: rootThreadID)
    }

    @MainActor
    private func refresh() async {
        guard !isLoading, client.state == .connected else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let fetched = try await client.threadDescendants(threadID: rootThreadID)
            guard !Task.isCancelled else { return }
            threads = fetched
            hasLoaded = true
        } catch { errorMessage = client.userFacingMessage(for: error) }
    }
}

private struct CodexSubagentRow: View {
    let record: RemoteThreadRecord
    var hasMissingParent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(CodexThreadControlPolicy.title(for: record), systemImage: "person.crop.rectangle.stack")
                .font(.headline).lineLimit(2)
            if let role = record.agentRole, !role.isEmpty { Text(role).font(.subheadline) }
            Text(CodexThreadControlPolicy.statusTitle(record.status)).font(.caption).foregroundStyle(.secondary)
            if hasMissingParent {
                Text("Parent was not included in the returned tree.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CodexSubagentThreadView: View {
    @ObservedObject var client: AppServerClient
    let threadID: String
    let rootThreadID: String
    let fallback: RemoteThreadRecord?
    let openThread: (String) -> Void
    let returnToWorkbench: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var history = CodexSubagentHistoryModel()

    private var record: RemoteThreadRecord? { client.threadRecordsByID[threadID] ?? fallback }
    private var historyMatches: Bool { history.matches(threadID: threadID, generation: client.connectionGeneration) }
    private var isActive: Bool {
        (historyMatches && history.hasActiveTurn) || record?.status?.type == "active"
    }
    private var refreshContext: RefreshContext {
        .init(threadID: threadID, generation: client.connectionGeneration,
              connected: client.state == .connected, foreground: scenePhase == .active)
    }
    private var children: [RemoteThreadRecord] {
        client.threadRecordsByID.values.filter { $0.parentThreadID == threadID && $0.id != threadID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        List {
            Section {
                if let record {
                    Text(CodexThreadControlPolicy.title(for: record)).font(.headline)
                    Text(CodexThreadControlPolicy.statusTitle(record.status)).foregroundStyle(.secondary)
                    if let role = record.agentRole { LabeledContent("Role", value: role) }
                    if let source = record.forkedFromID { LabeledContent("Forked from", value: source).font(.caption) }
                }
                Label("Read-only inspection", systemImage: "eye")
                Text("Messages and tool activity refresh while this agent is active. Opening a card sends no message or command.")
                    .font(.caption).foregroundStyle(.secondary)
                if history.isLoading { ProgressView("Reading thread…") }
                if let errorMessage = history.errorMessage { Text(errorMessage).foregroundStyle(.red) }
                if client.state != .connected { Text("Reconnect to refresh messages.").foregroundStyle(.secondary) }
            }
            Section("Navigation") {
                Button("Back to Parent Workbench", action: returnToWorkbench)
                if let parent = record?.parentThreadID, parent != rootThreadID, parent != threadID {
                    Button("Open Reported Parent") { openThread(parent) }
                }
                ForEach(children) { child in
                    Button { openThread(child.id) } label: { CodexSubagentRow(record: child) }
                }
            }
            if !historyMatches || history.turns.isEmpty {
                Section("Messages") {
                    Text(historyMatches && history.hasLoaded ? "No messages were returned." : "Messages have not loaded yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(history.turns) { turn in
                    Section {
                        if turn.items.isEmpty { Text("No items in this turn.").foregroundStyle(.secondary) }
                        ForEach(turn.items) { item in
                            CodexAgentMessageCard(item: item, openThread: openThread)
                                .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Turn \(turn.id)").textCase(nil)
                            Text(turn.status == "inProgress" ? "In progress" : turn.status.capitalized).textCase(nil)
                            if let model = turn.model { Text(model).textCase(nil) }
                        }
                    }
                }
            }
        }
        .navigationTitle(record.map(CodexThreadControlPolicy.title) ?? "Agent Thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh agent messages").disabled(history.isLoading || client.state != .connected)
            }
        }
        .task(id: refreshContext) { await followVisibleThread() }
        .refreshable { await refresh() }
        .onDisappear { history.cancelRefresh() }
    }

    @MainActor
    private func refresh() async {
        await history.refresh(client: client, threadID: threadID)
    }

    @MainActor
    private func followVisibleThread() async {
        history.prepare(threadID: threadID, generation: client.connectionGeneration)
        guard scenePhase == .active, client.state == .connected else {
            history.cancelRefresh()
            return
        }
        await refresh()
        while !Task.isCancelled {
            let wasActive = isActive
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard !Task.isCancelled, scenePhase == .active, client.state == .connected else { return }
            // Also fetch once after a live completion notification changes an active child to idle.
            if wasActive || isActive { await refresh() }
        }
    }

    private struct RefreshContext: Hashable {
        let threadID: String
        let generation: Int
        let connected: Bool
        let foreground: Bool
    }
}

enum CodexSubagentNavigation {
    static func path(current: [String], opening threadID: String, rootID: String) -> [String] {
        guard !threadID.isEmpty else { return current }
        guard threadID != rootID else { return [] }
        if let index = current.firstIndex(of: threadID) { return Array(current.prefix(index + 1)) }
        return current + [threadID]
    }
}
