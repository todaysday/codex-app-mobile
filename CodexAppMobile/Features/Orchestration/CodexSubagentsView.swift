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
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    private var record: RemoteThreadRecord? { client.threadRecordsByID[threadID] ?? fallback }
    private var transcript: String { client.transcriptByThread[threadID] ?? "" }
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
                Text("Refresh to fetch the latest messages. No message is sent by opening this view.")
                    .font(.caption).foregroundStyle(.secondary)
                if isLoading { ProgressView("Reading thread…") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
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
            Section("Messages") {
                if transcript.isEmpty {
                    Text(hasLoaded ? "No messages were returned." : "Messages have not loaded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle(record.map(CodexThreadControlPolicy.title) ?? "Agent Thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh agent messages").disabled(isLoading || client.state != .connected)
            }
        }
        .task(id: threadID) { await refresh() }
        .refreshable { await refresh() }
    }

    @MainActor
    private func refresh() async {
        guard !isLoading, client.state == .connected else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            _ = try await client.threadRead(threadID: threadID)
            guard !Task.isCancelled else { return }
            hasLoaded = true
        } catch { errorMessage = client.userFacingMessage(for: error) }
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
