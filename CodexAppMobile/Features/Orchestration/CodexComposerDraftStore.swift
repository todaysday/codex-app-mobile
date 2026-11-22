import Foundation

struct CodexComposerDraftScope: Hashable {
    let hostID: UUID
    let workspaceID: UUID
    let threadID: String?
}

struct CodexComposerContextToken: Identifiable, Equatable {
    let id: String
    let token: String
    let title: String
}

struct CodexComposerDraft: Equatable {
    var text = ""
    var contextTokens: [CodexComposerContextToken] = []

    var isEmpty: Bool { text.isEmpty && contextTokens.isEmpty }

    var requestText: String {
        (contextTokens.map(\.token) + [text.trimmingCharacters(in: .whitespacesAndNewlines)])
            .joined(separator: "\n")
    }

    func prepending(to newer: CodexComposerDraft) -> CodexComposerDraft {
        let text = self.text.isEmpty ? newer.text
            : newer.text.isEmpty ? self.text : self.text + "\n\n" + newer.text
        var seen: Set<String> = []
        let tokens = (contextTokens + newer.contextTokens).filter { seen.insert($0.id).inserted }
        return CodexComposerDraft(text: text, contextTokens: tokens)
    }
}

/// Everything used by an asynchronous dispatch is copied before the first suspension.
struct CodexComposerSubmission: Identifiable {
    let id = UUID()
    let scope: CodexComposerDraftScope
    let host: RemoteHost
    let workspace: ProjectWorkspace
    let draft: CodexComposerDraft
    let model: String?
    let reasoning: String?
    let collaborationModeID: String?
    let forceNewThread: Bool

    var targetThreadID: String? { forceNewThread ? nil : scope.threadID }

    func maySelectCreatedThread(currentScope: CodexComposerDraftScope?, isVisible: Bool) -> Bool {
        isVisible && targetThreadID == nil && currentScope == scope
    }
}

struct CodexComposerFailedDraft: Identifiable, Equatable {
    let id: UUID
    let draft: CodexComposerDraft
}

/// Application-owned memory only. Prompt text is never serialized to preferences or logs.
struct CodexComposerDraftStore {
    private var drafts: [CodexComposerDraftScope: CodexComposerDraft] = [:]
    private var submissions: [UUID: CodexComposerSubmission] = [:]
    private var failures: [CodexComposerDraftScope: [CodexComposerFailedDraft]] = [:]

    func draft(for scope: CodexComposerDraftScope) -> CodexComposerDraft {
        drafts[scope] ?? CodexComposerDraft()
    }

    mutating func save(_ draft: CodexComposerDraft, for scope: CodexComposerDraftScope) {
        if draft.isEmpty {
            drafts.removeValue(forKey: scope)
        } else {
            drafts[scope] = draft
        }
    }

    mutating func switchScope(
        from loadedScope: CodexComposerDraftScope?,
        to nextScope: CodexComposerDraftScope?,
        currentDraft: CodexComposerDraft
    ) -> CodexComposerDraft {
        // The loaded scope, not the possibly already changed selection, owns the visible text.
        if let loadedScope { save(currentDraft, for: loadedScope) }
        return nextScope.map { draft(for: $0) } ?? CodexComposerDraft()
    }

    func hasPendingSubmission(in scope: CodexComposerDraftScope) -> Bool {
        submissions.values.contains { $0.scope == scope }
    }

    @discardableResult
    mutating func begin(_ submission: CodexComposerSubmission) -> Bool {
        guard !hasPendingSubmission(in: submission.scope) else { return false }
        submissions[submission.id] = submission
        save(CodexComposerDraft(), for: submission.scope)
        return true
    }

    mutating func complete(_ submissionID: UUID) {
        submissions.removeValue(forKey: submissionID)
    }

    mutating func fail(_ submissionID: UUID) {
        guard let submission = submissions.removeValue(forKey: submissionID) else { return }
        failures[submission.scope, default: []].append(
            CodexComposerFailedDraft(id: submission.id, draft: submission.draft)
        )
    }

    func failedDrafts(in scope: CodexComposerDraftScope) -> [CodexComposerFailedDraft] {
        failures[scope] ?? []
    }

    /// Only an explicit user action merges saved input into a draft. It never sends a request.
    @discardableResult
    mutating func restoreFailure(_ id: UUID, in scope: CodexComposerDraftScope) -> CodexComposerDraft? {
        guard var saved = failures[scope], let index = saved.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let recovered = saved.remove(at: index).draft.prepending(to: draft(for: scope))
        if saved.isEmpty {
            failures.removeValue(forKey: scope)
        } else {
            failures[scope] = saved
        }
        save(recovered, for: scope)
        return recovered
    }
}

enum CodexComposerSubmissionError: LocalizedError {
    case activeTurnUnavailable

    var errorDescription: String? {
        "This thread is active, but its turn ID is unavailable. Refresh the thread before sending again."
    }
}

struct CodexComposerDispatchResult {
    let threadID: String
    let threadDetail: CodexThreadDetail?
    /// A nil result means the prompt steered an existing turn.
    let startedTurn: AppServerClient.TurnStartResult?
}

extension CodexComposerSubmission {
    @MainActor
    func dispatch(
        using client: AppServerClient,
        connect: (@MainActor (RemoteHost) async throws -> Void)? = nil
    ) async throws -> CodexComposerDispatchResult {
        let neededConnection = !client.isConnected(to: host.id)
        if neededConnection {
            if let connect { try await connect(host) }
            else { try await client.connect(to: host) }
        }
        guard client.isConnected(to: host.id) else { throw CodexOfficialError.connectionChanged }
        let generation = client.connectionGeneration

        @MainActor func checkConnection() throws {
            guard client.connectionGeneration == generation, client.isConnected(to: host.id) else {
                throw CodexOfficialError.connectionChanged
            }
        }

        let threadID: String
        let detail: CodexThreadDetail?
        if let targetThreadID {
            threadID = targetThreadID
            let record = client.threadRecordsByID[threadID]
            let activeTurnID = client.activeTurnID(for: threadID)
            let needsReconciliation = neededConnection || record == nil || record?.status?.type == "notLoaded"
                || (record?.status?.type == "active" && (activeTurnID?.isEmpty ?? true))
            if needsReconciliation {
                // Resume attaches live events. Read reconciles history after reconnect or missing state.
                _ = try await client.threadResume(threadID: threadID)
                try checkConnection()
                detail = try await client.threadRead(threadID: threadID)
                try checkConnection()
            } else {
                detail = nil
            }
        } else {
            threadID = try await client.threadStart(
                cwd: workspace.remotePath, approvalPolicy: workspace.defaultApprovalPolicy, model: model
            )
            try checkConnection()
            detail = nil
        }

        guard !threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppServerClientError.malformedResponse
        }
        guard client.threadRecordsByID[threadID]?.canAcceptDirectInput != false else {
            throw AppServerClientError.readOnlyThread
        }
        let startedTurn: AppServerClient.TurnStartResult?
        if let activeTurnID = client.activeTurnID(for: threadID), !activeTurnID.isEmpty {
            try await client.turnSteer(
                threadID: threadID, expectedTurnID: activeTurnID, inputText: draft.requestText
            )
            startedTurn = nil
        } else {
            guard client.activeTurnID(for: threadID) == nil,
                  client.threadRecordsByID[threadID]?.status?.type != "active",
                  !client.compactingThreads.contains(threadID) else {
                throw CodexComposerSubmissionError.activeTurnUnavailable
            }
            startedTurn = try await client.turnStart(
                threadID: threadID, inputText: draft.requestText, model: model,
                effort: reasoning, collaborationModeID: collaborationModeID
            )
        }
        try checkConnection()
        return CodexComposerDispatchResult(threadID: threadID, threadDetail: detail, startedTurn: startedTurn)
    }
}
