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
    @State private var detail: CodexThreadDetail?

    private var record: RemoteThreadRecord? { client.threadRecordsByID[threadID] ?? fallback }
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
            Section("Messages and actions") {
                if let detail, !detail.turns.isEmpty {
                    ForEach(detail.turns) { turn in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text("Turn \(turn.id.prefix(8))").font(.caption.weight(.semibold))
                                Spacer()
                                Text(turn.status).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(turn.items) { item in
                                CodexSubagentItemCard(item: item)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                    }
                } else {
                    Text(hasLoaded ? "No messages were returned." : "Messages have not loaded yet.")
                        .foregroundStyle(.secondary)
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
            let loaded = try await client.threadRead(threadID: threadID)
            guard !Task.isCancelled, loaded.threadID == threadID else { return }
            detail = loaded
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


/// View-only projection: no request, turn or approval operation is attached to a card.
struct CodexSubagentCardInfo: Equatable {
    let title: String
    let symbol: String
    let summary: String?
    let status: String?
    let details: String?

    init(item: CodexTurnItem) {
        switch item {
        case .userMessage(_, let text):
            title = "User"; symbol = "person.fill"; summary = text; status = nil; details = nil
        case .agentMessage(_, let text):
            title = "Agent"; symbol = "bubble.left.fill"; summary = text; status = nil; details = nil
        case .plan(_, let text):
            title = "Plan"; symbol = "list.bullet.clipboard"; summary = text; status = nil; details = nil
        case .reasoning(_, let text):
            title = "Reasoning summary"; symbol = "brain.head.profile"
            summary = text.isEmpty ? "No summary available." : text; status = nil; details = nil
        case .commandExecution(_, let command, let state, let output):
            title = "Command"; symbol = "terminal"; summary = command; status = state; details = output
        case .fileChange(_, let state, let changedFiles):
            title = "File changes"; symbol = "doc.badge.gearshape"
            summary = "\(changedFiles) file(s) reported"; status = state; details = nil
        case .toolCall(_, let tool, let state, let output):
            title = "Tool · \(tool)"; symbol = "wrench.adjustable"
            summary = nil; status = state; details = output
        case .agentAction(_, let action, let state, let output):
            title = "Agent action · \(action)"; symbol = "person.2"
            summary = nil; status = state; details = output
        case .other(_, let type):
            title = "Other item · \(type)"; symbol = "square.stack.3d.up"
            summary = "This item type is not fully represented by the mobile reader."
            status = nil; details = nil
        }
    }
}

struct CodexSubagentItemCard: View {
    let item: CodexTurnItem
    @State private var detailsExpanded = false

    private var info: CodexSubagentCardInfo { .init(item: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(info.title, systemImage: info.symbol)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(3)
                Spacer(minLength: 6)
                if let status = info.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let summary = info.summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let details = info.details, !details.isEmpty {
                DisclosureGroup("Tool output and details", isExpanded: $detailsExpanded) {
                    ScrollView(.horizontal) {
                        Text(details)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}


// MARK: - Safe read-only workspace explorer (official fs/* App Server RPCs)

enum CodexWorkspacePathPolicy {
    static let maxPreviewBytes = 512 * 1024

    static func normalizedRoot(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\u{0}") else { return nil }
        let clean = (path as NSString).standardizingPath
        return clean.hasPrefix("/") ? clean : nil
    }

    static func contains(path: String, root: String) -> Bool {
        guard let base = normalizedRoot(root), let candidate = normalizedRoot(path) else { return false }
        return candidate == base || base == "/" || candidate.hasPrefix(base + "/")
    }

    static func childPath(directory: String, name: String, root: String) -> String? {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"),
              !name.contains("\u{0}"), contains(path: directory, root: root) else { return nil }
        let joined = (directory as NSString).appendingPathComponent(name)
        return contains(path: joined, root: root) ? joined : nil
    }

    static func canPreview(sizeBytes: Int?) -> Bool {
        guard let sizeBytes else { return false }
        return (0...maxPreviewBytes).contains(sizeBytes)
    }
}

struct CodexWorkspaceEntry: Identifiable {
    let name: String
    let isDirectory: Bool
    let isFile: Bool
    var id: String { name }
}

struct CodexWorkspacePreview: Identifiable {
    let path: String
    let text: String
    var id: String { path }
}

struct CodexWorkspaceFilesView: View {
    @ObservedObject var client: AppServerClient
    let rootPath: String
    @Environment(\.dismiss) private var dismiss
    @State private var directory: String
    @State private var entries: [CodexWorkspaceEntry] = []
    @State private var preview: CodexWorkspacePreview?
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    init(client: AppServerClient, rootPath: String) {
        self.client = client
        self.rootPath = rootPath
        _directory = State(initialValue: CodexWorkspacePathPolicy.normalizedRoot(rootPath) ?? rootPath)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(directory).font(.caption.monospaced()).textSelection(.enabled)
                    if directory != CodexWorkspacePathPolicy.normalizedRoot(rootPath) {
                        Button("Up one folder", systemImage: "arrow.up.to.line") {
                            let parent = (directory as NSString).deletingLastPathComponent
                            guard CodexWorkspacePathPolicy.contains(path: parent, root: rootPath) else { return }
                            directory = parent
                            Task { await refresh() }
                        }
                    }
                    if isLoading { ProgressView("Loading files…") }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
                Section("Workspace files") {
                    ForEach(entries) { entry in
                        Button {
                            Task { await open(entry) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                                Text(entry.name)
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if entry.isDirectory { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                            }
                        }
                    }
                    if hasLoaded && entries.isEmpty {
                        Text("No readable entries were returned.").foregroundStyle(.secondary)
                    }
                    if entries.count == 200 {
                        Text("Showing at most 200 items in this folder.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(isLoading)
                }
            }
            .sheet(item: $preview) { item in
                NavigationStack {
                    ScrollView {
                        Text(item.text)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle((item.path as NSString).lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { preview = nil } } }
                }
            }
            .task { await refresh() }
        }
    }

    @MainActor
    private func refresh() async {
        guard !isLoading, client.state == .connected else { return }
        guard CodexWorkspacePathPolicy.contains(path: directory, root: rootPath) else {
            errorMessage = "The folder is outside this workspace."; return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let requested = directory
        do {
            let result = try await client.officialRequest(method: "fs/readDirectory",
                                                           params: .object(["path": .string(requested)]))
            guard !Task.isCancelled, directory == requested else { return }
            let values = result.objectValue?["entries"]?.arrayValue ?? []
            entries = Array(values.compactMap { item -> CodexWorkspaceEntry? in
                guard let object = item.objectValue,
                      let name = object["fileName"]?.stringValue,
                      CodexWorkspacePathPolicy.childPath(directory: requested, name: name, root: rootPath) != nil else {
                    return nil
                }
                return .init(name: name, isDirectory: object["isDirectory"]?.boolValue ?? false,
                             isFile: object["isFile"]?.boolValue ?? false)
            }.prefix(200))
            hasLoaded = true
        } catch { errorMessage = client.userFacingMessage(for: error) }
    }

    @MainActor
    private func open(_ entry: CodexWorkspaceEntry) async {
        guard !isLoading, client.state == .connected,
              let path = CodexWorkspacePathPolicy.childPath(directory: directory, name: entry.name, root: rootPath)
        else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await client.officialRequest(method: "fs/getMetadata",
                                                           params: .object(["path": .string(path)]))
            guard !Task.isCancelled else { return }
            guard let meta = result.objectValue else { errorMessage = "Invalid file metadata."; return }
            guard meta["isSymlink"]?.boolValue != true else {
                errorMessage = "Symlink targets are not followed by this explorer."; return
            }
            if meta["isDirectory"]?.boolValue == true {
                directory = path
                entries = []
                hasLoaded = false
                isLoading = false
                await refresh()
                return
            }
            guard meta["isFile"]?.boolValue == true else {
                errorMessage = "This is not a regular file."; return
            }
            let size = meta["sizeBytes"]?.intValue
            guard CodexWorkspacePathPolicy.canPreview(sizeBytes: size) else {
                errorMessage = size == nil
                    ? "The server did not provide file size. Refusing an unbounded full-file read."
                    : "The file exceeds the 512 KiB text-preview limit."
                return
            }
            let file = try await client.officialRequest(method: "fs/readFile",
                                                        params: .object(["path": .string(path)]))
            guard !Task.isCancelled, let base64 = file.objectValue?["dataBase64"]?.stringValue,
                  let data = Data(base64Encoded: base64), data.count <= CodexWorkspacePathPolicy.maxPreviewBytes else {
                errorMessage = "The file could not be decoded safely."; return
            }
            guard let text = String(data: data, encoding: .utf8), !text.contains("\u{0}") else {
                errorMessage = "Binary files do not have a text preview."; return
            }
            preview = .init(path: path, text: text)
        } catch { errorMessage = client.userFacingMessage(for: error) }
    }
}

// MARK: - Read-only worktree discovery through the existing SSH Git service

struct CodexWorktreesView: View {
    let host: RemoteHost
    let password: String
    let workspacePath: String
    @Environment(\.dismiss) private var dismiss
    @State private var items: [CodexGitWorktree] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    private let service = SSHGitService()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Read-only Git worktrees. No worktree is created, removed or switched here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if isLoading { ProgressView("Reading Git worktrees…") }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
                Section("Worktrees") {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.branch ?? (item.isDetached ? "Detached HEAD" : "Unknown branch"))
                                .font(.headline)
                            Text(item.path).font(.caption.monospaced()).textSelection(.enabled)
                            if item.isLocked { Label("Locked", systemImage: "lock").font(.caption) }
                        }
                    }
                    if items.isEmpty && !isLoading && errorMessage == nil {
                        Text("No worktrees returned.").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Worktrees")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(isLoading)
                }
            }
            .task { await refresh() }
        }
    }

    @MainActor
    private func refresh() async {
        guard !isLoading, host.hasSSHConfiguration else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await service.listWorktrees(host: host, password: password, workspacePath: workspacePath)
        } catch { errorMessage = error.localizedDescription }
    }
}
