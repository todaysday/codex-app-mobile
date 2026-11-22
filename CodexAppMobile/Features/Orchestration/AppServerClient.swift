import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class AppServerClient: ObservableObject {
    static let minimumSupportedCLIVersion = "0.106.0"

    enum State: String {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case failed
    }

    enum TurnStreamingPhase: String, Equatable {
        case thinking
        case responding
    }

    struct TurnStartResult: Equatable {
        let turnID: String
        let collaborationModeApplied: Bool
    }

    /// Called on the main actor when a turn completes.
    /// Parameters: threadID, status, response snippet (first ~200 chars of the transcript delta).
    var onTurnCompleted: ((_ threadID: String, _ status: String, _ responseSnippet: String) -> Void)?

    @Published private(set) var state: State = .disconnected
    @Published private(set) var lastErrorMessage = ""
    @Published private(set) var connectedEndpoint = ""
    @Published private(set) var pendingRequests: [AppServerPendingRequest] = []
    @Published private(set) var lastResolvedPendingRequest: AppServerResolvedPendingRequest?
    @Published private(set) var transcriptByThread: [String: String] = [:]
    @Published private(set) var activeTurnIDByThread: [String: String] = [:]
    @Published private(set) var turnStreamingPhaseByThread: [String: TurnStreamingPhase] = [:]
    @Published private(set) var availableModels: [AppServerModelDescriptor] = []
    @Published private(set) var availableCollaborationModes: [AppServerCollaborationModeDescriptor] = []
    @Published private(set) var availableSkills: [AppServerSkillSummary] = []
    @Published private(set) var availableApps: [AppServerAppSummary] = []
    @Published private(set) var availableSlashCommands: [AppServerSlashCommandDescriptor] = []
    @Published private(set) var rateLimits: [AppServerRateLimitSummary] = []
    @Published private(set) var contextUsageByThread: [String: AppServerContextUsageSummary] = [:]
    @Published var threadRecordsByID: [String: RemoteThreadRecord] = [:]
    @Published var threadGoalsByID: [String: CodexThreadGoal] = [:]
    @Published var threadPlansByID: [String: CodexThreadPlan] = [:]
    @Published var threadDiffsByID: [String: CodexThreadDiff] = [:]
    @Published var threadNamesByID: [String: String] = [:]
    @Published var compactingThreads: Set<String> = []
    @Published var unsupportedOfficialMethods: Set<String> = []
    var goalRevisionByThread: [String: Int] = [:]
    var threadNameRevisionByThread: [String: Int] = [:]
    var compactionAcknowledgedThreads: Set<String> = []
    private(set) var connectionGeneration = 0
    @Published private(set) var eventLog: [String] = []
    @Published private(set) var diagnostics = AppServerDiagnostics(
        minimumRequiredVersion: AppServerClient.minimumSupportedCLIVersion
    )

    private let session: URLSession
    private let credentialStore: AppServerCredentialStore
    private let router = AppServerMessageRouter()

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var reconnectAttempts = 0
    private let maxReconnectDelaySeconds: TimeInterval = 30
    private var autoReconnectEnabled = false
    private var lastHost: RemoteHost?
    var hasReceivedMessageOnCurrentConnection = false
    private var streamedItemPrefixKeys: Set<String> = []
    /// Tracks the transcript snapshot before a turn starts so we can extract the response delta.
    private var transcriptSnapshotBeforeTurn: [String: String] = [:]
    private var slashCommandCatalogRebuildCount = 0
    private var turnStateRevisionByThread: [String: Int] = [:]
    private var transcriptRevisionByThread: [String: Int] = [:]
    private var statusRevisionByThread: [String: Int] = [:]
    private var lastReportedStatusByThread: [String: AppServerThreadStatus] = [:]
    private(set) var latestTurnIDByThread: [String: String] = [:]
    private var respondingRequestIDs: Set<UUID> = []
    var requestOverrideForTesting: (@MainActor (String, JSONValue?) async throws -> JSONValue)?
    var responseOverrideForTesting: (@MainActor (AppServerPendingRequest, JSONValue) async throws -> Void)?

    struct CatalogRefreshOverrides {
        var modelCatalog: [AppServerModelDescriptor]?
        var collaborationModes: [AppServerCollaborationModeDescriptor]
        var skills: [AppServerSkillSummary]
        var apps: [AppServerAppSummary]
    }
    var catalogRefreshOverrides: CatalogRefreshOverrides?

    private let requestTimeoutSeconds: TimeInterval = 30
    private let overloadRetryMaxAttempts = 4

    #if canImport(UIKit)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(
        session: URLSession = AppServerConnectionSecurity.makeSession(),
        credentialStore: AppServerCredentialStore = KeychainAppServerCredentialStore()
    ) {
        self.session = session
        self.credentialStore = credentialStore
    }

    private func transition(
        to newState: State,
        endpoint: String? = nil,
        errorMessage: String? = nil
    ) {
        self.state = newState
        self.diagnostics.connectionState = newState.rawValue
        if let endpoint {
            self.connectedEndpoint = endpoint
        }
        if let errorMessage {
            self.lastErrorMessage = errorMessage
        } else if newState == .connected {
            self.lastErrorMessage = ""
        }
    }

    /// Whether the client is in a transient connection state where
    /// operations may temporarily fail but auto-reconnect will retry.
    var isConnectionTransient: Bool {
        self.state == .connecting || self.state == .reconnecting
    }

    func isConnected(to hostID: UUID) -> Bool {
        self.state == .connected && self.lastHost?.id == hostID
    }

    private func resetDiagnosticsForNewConnection() {
        self.diagnostics = AppServerDiagnostics(
            connectionState: self.state.rawValue,
            minimumRequiredVersion: Self.minimumSupportedCLIVersion
        )
    }

    private func markSuccessfulPing(latencyMS: Double) {
        let now = Date()
        self.diagnostics.lastPingLatencyMS = latencyMS
        self.diagnostics.lastSuccessfulPingAt = now
        self.diagnostics.lastCheckedAt = now
    }

    private func recordRPCError(method: String, error: Error) {
        let message = self.userFacingMessage(for: error)
        self.diagnostics.lastRPCErrorMessage = "\(method): \(message)"
        self.diagnostics.lastRPCErrorAt = Date()
    }

    /// Request extended background execution while active turns are in progress.
    /// Call when the app transitions to background and there are pending turns.
    func beginBackgroundProcessingIfNeeded() {
        #if canImport(UIKit)
        guard self.backgroundTaskID == .invalid,
              !self.activeTurnIDByThread.isEmpty else { return }
        self.backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "CodexTurnCompletion"
        ) { [weak self] in
            self?.endBackgroundProcessing()
        }
        #endif
    }

    /// End the extended background execution request.
    func endBackgroundProcessing() {
        #if canImport(UIKit)
        guard self.backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
        self.backgroundTaskID = .invalid
        #endif
    }

    /// End background task if no active turns remain.
    private func endBackgroundProcessingIfIdle() {
        #if canImport(UIKit)
        if self.activeTurnIDByThread.isEmpty {
            self.endBackgroundProcessing()
        }
        #endif
    }

    func connect(to host: RemoteHost) async throws {
        try await self.openConnection(to: host, resetReconnectAttempts: true)
    }

    func disconnect() {
        self.autoReconnectEnabled = false
        self.reconnectTask?.cancel()
        self.reconnectTask = nil
        self.teardownConnection(closeCode: .goingAway)
        self.activeTurnIDByThread.removeAll()
        self.turnStreamingPhaseByThread.removeAll()
        self.streamedItemPrefixKeys.removeAll()
        self.availableModels = []
        self.availableCollaborationModes = []
        self.availableSkills = []
        self.availableApps = []
        self.availableSlashCommands = []
        self.rateLimits = []
        self.lastResolvedPendingRequest = nil
        self.contextUsageByThread.removeAll()
        self.reconnectAttempts = 0
        self.diagnostics.reconnectAttemptCount = 0
        self.transition(to: .disconnected, endpoint: "", errorMessage: "")
        self.endBackgroundProcessing()
    }

    func appendLocalEcho(_ text: String, to threadID: String) {
        let existing = self.transcriptByThread[threadID] ?? ""
        let separator = existing.isEmpty ? "" : "\n"
        self.transcriptByThread[threadID] = existing + "\(separator)User: \(text)\nAssistant: "
        self.transcriptRevisionByThread[threadID, default: 0] &+= 1
    }

    func clearThreadTranscript(_ threadID: String) {
        self.transcriptByThread.removeValue(forKey: threadID)
    }

    func activeTurnID(for threadID: String?) -> String? {
        guard let threadID else { return nil }
        return self.activeTurnIDByThread[threadID]
    }

    func turnStreamingPhase(for threadID: String?) -> TurnStreamingPhase? {
        guard let threadID else { return nil }
        return self.turnStreamingPhaseByThread[threadID]
    }

    func runDiagnostics() async throws -> AppServerDiagnostics {
        guard self.state == .connected else {
            throw AppServerClientError.notConnected
        }

        let latency = try await self.measurePingLatency()
        self.markSuccessfulPing(latencyMS: latency)
        return self.diagnostics
    }

    func refreshRateLimits() async throws -> [AppServerRateLimitSummary] {
        guard self.state == .connected else {
            throw AppServerClientError.notConnected
        }

        do {
            let result = try await self.request(method: "account/rateLimits/read", params: nil)
            var parsed = Self.parseRateLimitCatalog(result)
            if parsed.isEmpty, let object = result.objectValue, let data = object["data"] {
                parsed = Self.parseRateLimitCatalog(data)
            }
            self.rateLimits = parsed
            if let planType = Self.parsePlanType(from: result) {
                self.diagnostics.planType = planType
            }
            return parsed
        } catch let AppServerClientError.remote(code, message) where code == -32601 {
            self.rateLimits = []
            self.appendEvent("account/rateLimits/read unavailable: \(message)")
            return []
        }
    }

    func contextUsage(for threadID: String?) -> AppServerContextUsageSummary? {
        guard let threadID else { return nil }
        return self.contextUsageByThread[threadID]
    }

    func mcpServerStatusHeadline(limit: Int = 100) async throws -> String {
        guard self.state == .connected else {
            throw AppServerClientError.notConnected
        }

        let clampedLimit = max(1, min(100, limit))
        let params: JSONValue = .object([
            "limit": .number(Double(clampedLimit))
        ])

        do {
            let result = try await self.request(method: "mcpServerStatus/list", params: params)
            let rows = Self.dataArray(from: result, fallbackKeys: ["servers", "mcpServers"])
            guard !rows.isEmpty else {
                return L10n.text("MCP servers: none reported.")
            }

            var items: [String] = []
            var seenNames: Set<String> = []

            for row in rows {
                guard let object = row.objectValue else { continue }
                let name = Self.findString(
                    in: object,
                    paths: [
                        ["name"],
                        ["id"],
                        ["server", "name"],
                        ["displayName"],
                    ]
                ) ?? L10n.text("unnamed")
                guard seenNames.insert(name).inserted else { continue }

                let enabled = Self.findBool(
                    in: object,
                    paths: [
                        ["enabled"],
                        ["isEnabled"],
                        ["active"],
                        ["isActive"],
                    ]
                )
                let status = Self.findString(
                    in: object,
                    paths: [
                        ["authStatus"],
                        ["status"],
                        ["oauth", "status"],
                        ["auth", "status"],
                    ]
                )

                let normalizedStatus = status?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? ""
                let runningState: String
                if let enabled {
                    runningState = enabled ? L10n.text("running") : L10n.text("stopped")
                } else if normalizedStatus.contains("connected")
                    || normalizedStatus.contains("ready")
                    || normalizedStatus.contains("running")
                    || normalizedStatus == "ok" {
                    runningState = L10n.text("running")
                } else if normalizedStatus.contains("disconnected")
                    || normalizedStatus.contains("stopped")
                    || normalizedStatus.contains("error")
                    || normalizedStatus.contains("failed") {
                    runningState = L10n.text("stopped")
                } else {
                    runningState = L10n.text("unknown")
                }

                items.append("\(name)(\(runningState))")
            }

            guard !items.isEmpty else {
                return L10n.text("MCP servers: none reported.")
            }

            let displayLimit = 6
            let shown = Array(items.prefix(displayLimit))
            let hiddenCount = max(0, items.count - shown.count)
            let suffix = hiddenCount > 0 ? L10n.format(", ... (+%@)", "\(hiddenCount)") : ""
            let listWithSuffix = shown.joined(separator: ", ") + suffix
            return L10n.format("MCP servers: %@", listWithSuffix)
        } catch let AppServerClientError.remote(code, message) where code == -32601 {
            self.appendEvent("mcpServerStatus/list unavailable: \(message)")
            return L10n.text("MCP status is unavailable on this server.")
        }
    }


    static let allThreadSourceKinds = [
        "cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview",
        "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown",
    ]

    /// `limit` is a page size, not a truncation limit for the user's history.
    func threadList(archived: Bool? = nil, limit: Int = 100,
                    parentThreadID: String? = nil, ancestorThreadID: String? = nil,
                    sourceKinds: [String]? = nil) async throws -> [RemoteThreadRecord] {
        let parent = Self.nonEmpty(parentThreadID)
        let ancestor = Self.nonEmpty(ancestorThreadID)
        guard parent == nil || ancestor == nil else { throw AppServerClientError.invalidThreadFilters }
        let generation = self.connectionGeneration
        let statusRevisions = self.statusRevisionByThread
        let nameRevisions = self.threadNameRevisionByThread
        var filters: [String: JSONValue] = [
            "limit": .number(Double(min(100, max(1, limit)))),
            "sourceKinds": .array((sourceKinds ?? Self.allThreadSourceKinds).map(JSONValue.string)),
        ]
        if let archived { filters["archived"] = .bool(archived) }
        if let parent { filters["parentThreadId"] = .string(parent) }
        if let ancestor { filters["ancestorThreadId"] = .string(ancestor) }
        var records: [RemoteThreadRecord] = []
        var indices: [String: Int] = [:]
        var cursor: String?
        var seenCursors: Set<String> = []
        while true {
            try Task.checkCancellation()
            guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
            var params = filters
            if let cursor { params["cursor"] = .string(cursor) }
            let result: JSONValue
            do {
                result = try await self.request(method: "thread/list", params: .object(params))
            } catch {
                // Never remove an explicitly requested relationship or source restriction.
                guard cursor == nil, parent == nil, ancestor == nil, sourceKinds == nil,
                      filters["sourceKinds"] != nil, Self.isUnsupportedSourceKinds(error) else { throw error }
                filters.removeValue(forKey: "sourceKinds")
                self.appendEvent("This server does not support all-source history. Showing its legacy interactive sources.")
                continue
            }
            guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
            let payload: ThreadListResponsePayload = try self.decode(result, as: ThreadListResponsePayload.self)
            for thread in payload.data {
                let record = Self.threadRecord(thread, archived: archived ?? false)
                if let index = indices[record.id] {
                    if record.updatedAt > records[index].updatedAt { records[index] = record }
                } else {
                    indices[record.id] = records.count
                    records.append(record)
                }
            }
            guard let next = payload.nextCursor else { break }
            guard seenCursors.insert(next).inserted else {
                throw AppServerClientError.incompleteHistory(method: "thread/list")
            }
            cursor = next
        }
        try Task.checkCancellation()
        for index in records.indices {
            let id = records[index].id
            if statusRevisions[id, default: 0] != self.statusRevisionByThread[id, default: 0] {
                records[index].status = self.lastReportedStatusByThread[id]
            }
            if nameRevisions[id, default: 0] != self.threadNameRevisionByThread[id, default: 0] {
                records[index].name = self.threadNamesByID[id]
            }
            self.rememberThread(records[index])
        }
        return records
    }

    func threadLoadedList(limit: Int = 100) async throws -> [String] {
        let generation = self.connectionGeneration
        var ids: [String] = []
        var seenIDs: Set<String> = []
        var cursor: String?
        var seenCursors: Set<String> = []
        while true {
            try Task.checkCancellation()
            guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
            var params: [String: JSONValue] = ["limit": .number(Double(min(100, max(1, limit))))]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await self.request(method: "thread/loaded/list", params: .object(params))
            guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
            let payload: ThreadLoadedListResponsePayload = try self.decode(result, as: ThreadLoadedListResponsePayload.self)
            for id in payload.data where seenIDs.insert(id).inserted { ids.append(id) }
            guard let next = payload.nextCursor else { return ids }
            guard seenCursors.insert(next).inserted else {
                throw AppServerClientError.incompleteHistory(method: "thread/loaded/list")
            }
            cursor = next
        }
    }

    func threadRead(threadID: String, turnsCursor: String? = nil,
                    turnsSortDirection: String = "asc") async throws -> CodexThreadDetail {
        let generation = self.connectionGeneration
        let revision = self.turnStateRevisionByThread[threadID, default: 0]
        let transcriptRevision = self.transcriptRevisionByThread[threadID, default: 0]
        let statusRevision = self.statusRevisionByThread[threadID, default: 0]
        let nameRevision = self.threadNameRevisionByThread[threadID, default: 0]
        let wasCompactionAcknowledged = self.compactionAcknowledgedThreads.contains(threadID)
        let result = try await self.request(method: "thread/read", params: .object([
            "threadId": .string(threadID), "includeTurns": .bool(false),
        ]))
        guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
        let payload: ThreadReadResponsePayload = try self.decode(result, as: ThreadReadResponsePayload.self)
        guard payload.thread.id == threadID else { throw AppServerClientError.malformedResponse }
        let thread = try await self.hydrateThread(payload.thread, cursor: turnsCursor, sortDirection: turnsSortDirection)
        return try self.acceptThreadSnapshot(thread, model: payload.model, effort: payload.reasoningEffort,
                                             generation: generation, revision: revision,
                                             transcriptRevision: transcriptRevision, statusRevision: statusRevision,
                                             nameRevision: nameRevision, wasCompactionAcknowledged: wasCompactionAcknowledged)
    }

    func ensureSafeThreadSnapshot(threadID: String) async throws -> CodexThreadDetail {
        try await self.threadRead(threadID: threadID)
    }

    private func rememberThread(_ record: RemoteThreadRecord) {
        self.threadRecordsByID[record.id] = record
        self.threadNamesByID[record.id] = record.name
    }

    private func hydrateThread(_ metadata: ThreadReadThreadPayload, cursor initialCursor: String? = nil,
                               sortDirection: String = "asc") async throws -> ThreadReadThreadPayload {
        guard sortDirection == "asc" || sortDirection == "desc" else {
            throw CodexOfficialError.invalidInput("Choose an ascending or descending history order.")
        }
        let generation = self.connectionGeneration
        let hasExplicitRange = initialCursor != nil || sortDirection != "asc"
        let needsPages = metadata.historyMode == "paginated" || hasExplicitRange
            || metadata.turns.contains(where: { $0.itemsView != nil && $0.itemsView != "full" })

        func legacyHistory() async throws -> ThreadReadThreadPayload {
            let result = try await self.request(method: "thread/read", params: .object([
                "threadId": .string(metadata.id), "includeTurns": .bool(true),
            ]))
            guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
            let payload = try self.decode(result, as: ThreadReadResponsePayload.self)
            guard payload.thread.id == metadata.id else { throw AppServerClientError.malformedResponse }
            guard !payload.thread.turns.contains(where: { $0.itemsView != nil && $0.itemsView != "full" }) else {
                throw AppServerClientError.incompleteHistory(method: "thread/read")
            }
            return payload.thread
        }

        if !needsPages {
            // Older resumes may already contain full history even when excludeTurns was requested.
            if !metadata.turns.isEmpty { return metadata }
            return try await legacyHistory()
        }
        if self.unsupportedOfficialMethods.contains("thread/turns/list") {
            guard !hasExplicitRange else { throw CodexOfficialError.unsupported("thread/turns/list") }
            return try await legacyHistory()
        }

        var thread = metadata
        var turns: [ThreadReadTurnPayload] = []
        var indices: [String: Int] = [:]
        var cursor = initialCursor
        var seenCursors = Set(initialCursor.map { [$0] } ?? [])
        while true {
            try Task.checkCancellation()
            guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
            var params: [String: JSONValue] = [
                "threadId": .string(metadata.id), "limit": .number(100),
                "sortDirection": .string(sortDirection), "itemsView": .string("full"),
            ]
            if let cursor { params["cursor"] = .string(cursor) }
            let result: JSONValue
            do {
                result = try await self.request(method: "thread/turns/list", params: .object(params))
            } catch let AppServerClientError.remote(code, _) where code == -32601 {
                guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
                self.unsupportedOfficialMethods.insert("thread/turns/list")
                guard !hasExplicitRange else { throw CodexOfficialError.unsupported("thread/turns/list") }
                return try await legacyHistory()
            }
            guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
            let page = try self.decode(result, as: ThreadTurnsListResponsePayload.self)
            for turn in page.data {
                guard turn.itemsView == nil || turn.itemsView == "full" else {
                    throw AppServerClientError.incompleteHistory(method: "thread/turns/list")
                }
                if let index = indices[turn.id] { turns[index] = turn }
                else { indices[turn.id] = turns.count; turns.append(turn) }
            }
            guard let next = page.nextCursor else { break }
            guard seenCursors.insert(next).inserted else {
                throw AppServerClientError.incompleteHistory(method: "thread/turns/list")
            }
            cursor = next
        }
        try Task.checkCancellation()
        thread.turns = sortDirection == "desc" ? Array(turns.reversed()) : turns
        return thread
    }

    private func acceptThreadSnapshot(_ thread: ThreadReadThreadPayload, model: String?, effort: String?,
                                      generation: Int, revision: Int, transcriptRevision: Int,
                                      statusRevision: Int, nameRevision: Int,
                                      wasCompactionAcknowledged: Bool) throws -> CodexThreadDetail {
        guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
        let detail = self.convertThread(thread, modelOverride: model, reasoningEffortOverride: effort)
        // A response requested before a new turn must not roll that live state back.
        guard revision == self.turnStateRevisionByThread[thread.id, default: 0] else { return detail }
        var record = Self.threadRecord(thread, existing: self.threadRecordsByID[thread.id], model: model, effort: effort)
        if statusRevision != self.statusRevisionByThread[thread.id, default: 0] {
            record.status = self.lastReportedStatusByThread[thread.id]
        }
        if nameRevision != self.threadNameRevisionByThread[thread.id, default: 0] {
            record.name = self.threadNamesByID[thread.id]
        }
        self.rememberThread(record)
        if transcriptRevision == self.transcriptRevisionByThread[thread.id, default: 0] {
            self.transcriptByThread[thread.id] = Self.renderThread(detail)
        }
        self.latestTurnIDByThread[thread.id] = thread.turns.last?.id
        if let active = thread.turns.last(where: { $0.status == "inProgress" }) {
            self.activeTurnIDByThread[thread.id] = active.id
            self.latestTurnIDByThread[thread.id] = active.id
            self.turnStreamingPhaseByThread[thread.id] = active.items.contains(where: { $0.type == "agentMessage" })
                ? .responding : .thinking
            var before = thread
            before.turns.removeAll(where: { $0.id == active.id })
            self.transcriptSnapshotBeforeTurn[thread.id] = Self.renderThread(self.convertThread(before))
        } else if record.status?.type != "active" {
            self.activeTurnIDByThread.removeValue(forKey: thread.id)
            self.turnStreamingPhaseByThread.removeValue(forKey: thread.id)
            self.transcriptSnapshotBeforeTurn.removeValue(forKey: thread.id)
            self.clearStreamedItemPrefixKeys(for: thread.id)
            self.endBackgroundProcessingIfIdle()
        }
        self.reconcileOfficialSnapshot(threadID: thread.id, status: record.status,
                                       wasCompactionAcknowledged: wasCompactionAcknowledged)
        return detail
    }

    func threadStart(cwd: String, approvalPolicy: CodexApprovalPolicy, model: String?) async throws -> String {
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = (trimmedModel?.isEmpty == false) ? trimmedModel : nil

        func requestThreadStart(model: String?) async throws -> String {
            var params: [String: JSONValue] = [
                "cwd": .string(cwd),
                "approvalPolicy": .string(approvalPolicy.rawValue),
            ]
            if let model {
                params["model"] = .string(model)
            }

            let result = try await self.request(method: "thread/start", params: .object(params))
            let payload: ThreadLifecycleResponsePayload = try self.decode(result, as: ThreadLifecycleResponsePayload.self)
            return payload.thread.id
        }

        do {
            return try await requestThreadStart(model: normalizedModel)
        } catch {
            guard normalizedModel != nil,
                  Self.shouldRetryWithoutModel(error) else {
                throw error
            }
            self.appendEvent("thread/start rejected model; retrying without model.")
            return try await requestThreadStart(model: nil)
        }
    }

    func threadFork(threadID: String) async throws -> String {
        let params: JSONValue = .object([
            "threadId": .string(threadID),
        ])
        let result = try await self.request(method: "thread/fork", params: params)
        guard let object = result.objectValue,
              let forkedThreadID = Self.findString(
                in: object,
                paths: [
                    ["thread", "id"],
                    ["threadId"],
                    ["id"],
                ]
              )
        else {
            throw AppServerClientError.malformedResponse
        }
        return forkedThreadID
    }

    enum ReviewDelivery: String {
        case inline
        case detached
    }

    enum ReviewTarget: Equatable {
        case uncommittedChanges
        case baseBranch(String)
        case commit(sha: String, title: String?)
        case custom(String)

        fileprivate var jsonValue: JSONValue {
            switch self {
            case .uncommittedChanges:
                return .object([
                    "type": .string("uncommittedChanges")
                ])
            case .baseBranch(let baseBranch):
                return .object([
                    "type": .string("baseBranch"),
                    "baseBranch": .string(baseBranch)
                ])
            case .commit(let sha, let title):
                var payload: [String: JSONValue] = [
                    "type": .string("commit"),
                    "sha": .string(sha)
                ]
                if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    payload["title"] = .string(title)
                }
                return .object(payload)
            case .custom(let instructions):
                return .object([
                    "type": .string("custom"),
                    "instructions": .string(instructions)
                ])
            }
        }
    }

    @discardableResult
    func reviewStart(
        threadID: String,
        delivery: ReviewDelivery = .inline,
        target: ReviewTarget = .uncommittedChanges
    ) async throws -> String {
        let generation = self.connectionGeneration
        let revisions = self.turnStateRevisionByThread
        let targetCandidates: [JSONValue]
        switch target {
        case .baseBranch(let baseBranch):
            targetCandidates = [
                target.jsonValue,
                .object([
                    "type": .string("baseBranch"),
                    "branch": .string(baseBranch)
                ]),
                .object([
                    "type": .string("baseBranch"),
                    "branchName": .string(baseBranch)
                ])
            ]
        default:
            targetCandidates = [target.jsonValue]
        }

        var result: JSONValue?
        for (index, targetCandidate) in targetCandidates.enumerated() {
            do {
                let params: JSONValue = .object([
                    "threadId": .string(threadID),
                    "delivery": .string(delivery.rawValue),
                    "target": targetCandidate
                ])
                result = try await self.request(method: "review/start", params: params)
                break
            } catch {
                let shouldRetry = index < targetCandidates.count - 1
                    && Self.shouldRetryReviewStartTarget(error)
                if shouldRetry {
                    continue
                }
                throw error
            }
        }

        guard let result else {
            throw AppServerClientError.malformedResponse
        }
        guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
        guard let object = result.objectValue else {
            throw AppServerClientError.malformedResponse
        }

        let reviewThreadID = Self.findString(
            in: object,
            paths: [
                ["reviewThreadId"],
                ["threadId"],
                ["thread", "id"],
            ]
        ) ?? threadID

        if let turnID = Self.findString(in: object, paths: [["turn", "id"]]),
           revisions[reviewThreadID, default: 0] == self.turnStateRevisionByThread[reviewThreadID, default: 0] {
            self.activeTurnIDByThread[reviewThreadID] = turnID
            self.latestTurnIDByThread[reviewThreadID] = turnID
            self.turnStateRevisionByThread[reviewThreadID, default: 0] &+= 1
            self.turnStreamingPhaseByThread[reviewThreadID] = .thinking
        }
        return reviewThreadID
    }

    func threadResume(threadID: String) async throws -> CodexThreadDetail {
        let generation = self.connectionGeneration
        let revision = self.turnStateRevisionByThread[threadID, default: 0]
        let transcriptRevision = self.transcriptRevisionByThread[threadID, default: 0]
        let statusRevision = self.statusRevisionByThread[threadID, default: 0]
        let nameRevision = self.threadNameRevisionByThread[threadID, default: 0]
        let wasCompactionAcknowledged = self.compactionAcknowledgedThreads.contains(threadID)
        let result: JSONValue
        do {
            result = try await self.request(method: "thread/resume", params: .object([
                "threadId": .string(threadID), "excludeTurns": .bool(true),
            ]))
        } catch let AppServerClientError.remote(code, message) where code == -32602
                    && (message.lowercased().contains("excludeturns") || message.lowercased().contains("exclude_turns")) {
            guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
            result = try await self.request(method: "thread/resume", params: .object(["threadId": .string(threadID)]))
        }
        guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
        let payload: ThreadResumeResponsePayload = try self.decode(result, as: ThreadResumeResponsePayload.self)
        guard payload.thread.id == threadID else { throw AppServerClientError.malformedResponse }
        let thread = try await self.hydrateThread(payload.thread)
        return try self.acceptThreadSnapshot(thread, model: payload.model, effort: payload.reasoningEffort,
                                             generation: generation, revision: revision,
                                             transcriptRevision: transcriptRevision, statusRevision: statusRevision,
                                             nameRevision: nameRevision, wasCompactionAcknowledged: wasCompactionAcknowledged)
    }

    func threadArchive(threadID: String, archived: Bool) async throws {
        let params: JSONValue = .object([
            "threadId": .string(threadID),
        ])
        let method = archived ? "thread/archive" : "thread/unarchive"
        _ = try await self.request(method: method, params: params)
    }

    @discardableResult
    func turnStart(
        threadID: String,
        inputText: String,
        model: String?,
        effort: String?,
        collaborationModeID: String? = nil
    ) async throws -> TurnStartResult {
        guard self.threadRecordsByID[threadID]?.canAcceptDirectInput != false else {
            throw AppServerClientError.readOnlyThread
        }
        guard self.activeTurnIDByThread[threadID] == nil,
              self.threadRecordsByID[threadID]?.status?.type != "active" else {
            throw CodexOfficialError.threadBusy
        }
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = (trimmedModel?.isEmpty == false) ? trimmedModel : nil
        let trimmedEffort = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEffort = (trimmedEffort?.isEmpty == false) ? trimmedEffort : nil
        let normalizedCollaborationModeID = Self.nonEmpty(collaborationModeID)

        func requestTurnStart(
            model: String?,
            effort: String?,
            collaborationModeID: String?
        ) async throws -> TurnStartResult {
            let generation = self.connectionGeneration
            let revision = self.turnStateRevisionByThread[threadID, default: 0]
            var params: [String: JSONValue] = [
                "threadId": .string(threadID),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(inputText),
                    ])
                ]),
            ]
            var collaborationModeApplied = false

            if let model {
                params["model"] = .string(model)
            }
            if let effort {
                params["effort"] = .string(effort)
            }
            if let collaborationModeID {
                let collaborationModel = model
                    ?? self.availableModels.first(where: { $0.isDefault })?.model
                    ?? self.availableModels.first?.model
                    ?? Self.nonEmpty(self.diagnostics.currentModel)

                if let collaborationMode = Self.collaborationModePayload(
                    for: collaborationModeID,
                    model: collaborationModel,
                    effort: effort
                ) {
                    params["collaborationMode"] = collaborationMode
                    collaborationModeApplied = true
                } else {
                    self.appendEvent("turn/start skipped collaboration mode: unsupported mode id or unresolved model.")
                }
            }

            let result = try await self.request(method: "turn/start", params: .object(params))
            guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
            let payload: TurnStartResponsePayload = try self.decode(result, as: TurnStartResponsePayload.self)
            if revision == self.turnStateRevisionByThread[threadID, default: 0] {
                self.activeTurnIDByThread[threadID] = payload.turn.id
                self.latestTurnIDByThread[threadID] = payload.turn.id
                self.turnStateRevisionByThread[threadID, default: 0] &+= 1
                self.turnStreamingPhaseByThread[threadID] = .thinking
            }
            return TurnStartResult(
                turnID: payload.turn.id,
                collaborationModeApplied: collaborationModeApplied
            )
        }

        func requestTurnStartWithFallbacks(
            model: String?,
            effort: String?,
            collaborationModeID: String?
        ) async throws -> TurnStartResult {
            do {
                return try await requestTurnStart(
                    model: model,
                    effort: effort,
                    collaborationModeID: collaborationModeID
                )
            } catch {
                if effort != nil,
                   Self.shouldRetryWithoutEffort(error) {
                    self.appendEvent("turn/start rejected effort; retrying without effort.")
                    return try await requestTurnStartWithFallbacks(
                        model: model,
                        effort: nil,
                        collaborationModeID: collaborationModeID
                    )
                }

                if model != nil,
                   Self.shouldRetryWithoutModel(error) {
                    self.appendEvent("turn/start rejected model; retrying without model.")
                    return try await requestTurnStartWithFallbacks(
                        model: nil,
                        effort: effort,
                        collaborationModeID: collaborationModeID
                    )
                }

                if collaborationModeID != nil,
                   Self.shouldRetryWithoutCollaborationMode(error) {
                    self.appendEvent("turn/start rejected collaboration mode; retrying without collaboration mode.")
                    return try await requestTurnStartWithFallbacks(
                        model: model,
                        effort: effort,
                        collaborationModeID: nil
                    )
                }

                throw error
            }
        }

        return try await requestTurnStartWithFallbacks(
            model: normalizedModel,
            effort: normalizedEffort,
            collaborationModeID: normalizedCollaborationModeID
        )
    }

    func turnSteer(threadID: String, expectedTurnID: String, inputText: String) async throws {
        guard self.threadRecordsByID[threadID]?.canAcceptDirectInput != false else {
            throw AppServerClientError.readOnlyThread
        }
        let generation = self.connectionGeneration
        let params: JSONValue = .object([
            "threadId": .string(threadID),
            "expectedTurnId": .string(expectedTurnID),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(inputText),
                ])
            ]),
        ])
        _ = try await self.request(method: "turn/steer", params: params)
        guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
        if self.activeTurnIDByThread[threadID] == expectedTurnID {
            self.turnStreamingPhaseByThread[threadID] = .thinking
        }
    }

    func turnInterrupt(threadID: String, turnID: String) async throws {
        let params: JSONValue = .object([
            "threadId": .string(threadID),
            "turnId": .string(turnID),
        ])
        _ = try await self.request(method: "turn/interrupt", params: params)
        // The acknowledgement only accepts the request; completion is a later event or snapshot.
    }

    func respondCommandApproval(
        request: AppServerPendingRequest,
        decision: AppServerCommandApprovalDecisionResponse
    ) async throws {
        try Self.validateOfficialCommandDecision(request: request, decision: decision)
        let result: JSONValue = .object(["decision": decision.jsonValue])
        try await self.respond(to: request, result: result)
    }

    func respondFileChangeApproval(
        request: AppServerPendingRequest,
        decision: AppServerFileApprovalDecision
    ) async throws {
        let result: JSONValue = .object(["decision": .string(decision.rawValue)])
        try await self.respond(to: request, result: result)
    }

    func respondUserInput(
        request: AppServerPendingRequest,
        answers: [String: [String]]
    ) async throws {
        try Self.validateOfficialUserInput(request: request, answers: answers)
        let answerObject = Dictionary(uniqueKeysWithValues: answers.map { key, values in
            (
                key,
                JSONValue.object([
                    "answers": .array(values.map { JSONValue.string($0) })
                ])
            )
        })

        let result: JSONValue = .object(["answers": .object(answerObject)])
        try await self.respond(to: request, result: result)
    }

    private func openConnection(to host: RemoteHost, resetReconnectAttempts: Bool) async throws {
        let url = try Self.resolveAppServerURL(raw: host.appServerURL)
        let request = try AppServerConnectionSecurity.request(
            endpoint: url.absoluteString,
            credentials: self.credentialStore.read(for: host.id),
            expectedAuthentication: host.appServerAuthentication
        )

        if resetReconnectAttempts {
            self.reconnectTask?.cancel()
            self.reconnectTask = nil
        }
        self.teardownConnection(closeCode: .normalClosure)
        let generation = self.connectionGeneration

        if self.lastHost?.id != host.id || self.lastHost?.appServerURL != host.appServerURL {
            self.transcriptByThread.removeAll()
            self.rateLimits.removeAll()
        }

        if resetReconnectAttempts {
            self.reconnectAttempts = 0
        }

        self.transition(to: .connecting, endpoint: url.absoluteString, errorMessage: "")
        self.autoReconnectEnabled = true
        self.lastHost = host
        self.availableModels = []
        self.availableCollaborationModes = []
        self.availableSkills = []
        self.availableApps = []
        self.availableSlashCommands = []
        self.lastResolvedPendingRequest = nil
        self.turnStreamingPhaseByThread.removeAll()
        self.streamedItemPrefixKeys.removeAll()
        self.resetDiagnosticsForNewConnection()
        self.diagnostics.reconnectAttemptCount = self.reconnectAttempts

        let task = self.session.webSocketTask(with: request)
        // 2 MiB previews are base64 encoded; keep a finite cap for the full JSON envelope.
        task.maximumMessageSize = 4 * 1_024 * 1_024
        self.webSocketTask = task
        self.hasReceivedMessageOnCurrentConnection = false
        task.resume()

        self.startReceiveLoop()
        self.startPingLoop()

        do {
            func initializeParams(includeExperimentalCapability: Bool) -> JSONValue {
                var payload: [String: JSONValue] = [
                    "clientInfo": .object([
                        "name": .string("CodexAppMobile"),
                        "version": .string("0.1.0")
                    ])
                ]
                if includeExperimentalCapability {
                    payload["capabilities"] = .object([
                        "experimentalApi": .bool(true),
                        "requiredHumanApproval": .bool(true)
                    ])
                }
                return .object(payload)
            }

            let initializeResult: JSONValue
            do {
                initializeResult = try await self.request(
                    method: "initialize",
                    params: initializeParams(includeExperimentalCapability: true)
                )
            } catch {
                guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
                guard Self.shouldRetryInitializeWithoutCapabilities(error) else {
                    throw error
                }
                self.appendEvent("initialize rejected capabilities; retrying without capabilities.")
                initializeResult = try await self.request(
                    method: "initialize",
                    params: initializeParams(includeExperimentalCapability: false)
                )
            }
            guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
            self.applyInitializeMetadata(from: initializeResult)
            try await self.sendEnvelope(
                JSONRPCEnvelope(
                    method: "initialized"
                )
            )
            guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
            if let cliVersion = self.nonEmptyOrNil(self.diagnostics.cliVersion),
               !Self.isVersion(cliVersion, atLeast: Self.minimumSupportedCLIVersion) {
                throw AppServerClientError.incompatibleVersion(
                    current: cliVersion,
                    minimum: Self.minimumSupportedCLIVersion
                )
            }
            self.reconnectAttempts = 0
            self.diagnostics.reconnectAttemptCount = 0
            self.transition(to: .connected, endpoint: url.absoluteString)
            Task { @MainActor [weak self] in
                guard let self, generation == self.connectionGeneration else { return }
                await self.refreshCatalogs(primaryCWD: nil)
            }
            self.diagnostics.lastCheckedAt = Date()
            self.appendEvent("Connected: \(host.name) @ \(url.absoluteString)")
        } catch {
            guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
            self.transition(
                to: .failed,
                endpoint: url.absoluteString,
                errorMessage: self.userFacingMessage(for: error)
            )
            self.teardownConnection(closeCode: .normalClosure)
            throw error
        }
    }

    func request(method: String, params: JSONValue?) async throws -> JSONValue {
        if let override = self.requestOverrideForTesting { return try await override(method, params) }
        let generation = self.connectionGeneration
        var attempt = 0
        while true {
            try Task.checkCancellation()
            guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
            do {
                let result = try await self.requestOnce(method: method, params: params)
                guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
                return result
            } catch let AppServerClientError.remote(code, message) where code == -32001 {
                guard attempt < self.overloadRetryMaxAttempts - 1 else {
                    self.recordRPCError(
                        method: method,
                        error: AppServerClientError.remote(code: code, message: message)
                    )
                    throw AppServerClientError.remote(code: code, message: message)
                }

                let baseDelaySeconds = pow(2.0, Double(attempt)) * 0.25
                let jitterSeconds = Double.random(in: 0...(baseDelaySeconds * 0.25))
                let delaySeconds = baseDelaySeconds + jitterSeconds
                self.appendEvent("Server overloaded; retrying \(method) in \(String(format: "%.2f", delaySeconds))s")

                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                attempt += 1
                continue
            } catch {
                if error is CancellationError {
                    throw error
                }
                self.recordRPCError(method: method, error: error)
                throw error
            }
        }
    }

    private func requestOnce(method: String, params: JSONValue?) async throws -> JSONValue {
        guard self.webSocketTask != nil else {
            throw AppServerClientError.notConnected
        }

        let generation = self.connectionGeneration
        let requestID = await self.router.makeRequestID()
        guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
        let idValue: JSONValue = .number(Double(requestID))
        let idKey = String(requestID)
        let envelope = JSONRPCEnvelope(id: idValue, method: method, params: params)

        return try await withCheckedThrowingContinuation { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.resume(throwing: AppServerClientError.notConnected)
                    return
                }

                await self.router.storeContinuation(continuation, for: idKey, generation: generation)

                do {
                    guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
                    try await self.sendEnvelope(envelope)
                } catch {
                    if let pending = await self.router.removeContinuation(for: idKey) {
                        pending.resume(throwing: error)
                    }
                    return
                }

                Task { [weak self] in
                    guard let self else { return }
                    let timeoutNanoseconds = UInt64(self.requestTimeoutSeconds * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    if let pending = await self.router.removeContinuation(for: idKey) {
                        pending.resume(throwing: AppServerClientError.timeout(method: method))
                    }
                }
            }
        }
    }

    func respond(to request: AppServerPendingRequest, result: JSONValue) async throws {
        guard self.pendingRequests.contains(where: {
            $0.instanceID == request.instanceID && $0.requestIDKey == request.requestIDKey && $0.rpcID == request.rpcID
        }), self.respondingRequestIDs.insert(request.instanceID).inserted else {
            throw AppServerOfficialRequestError.requestResolved
        }
        let generation = self.connectionGeneration
        defer {
            if generation == self.connectionGeneration { self.respondingRequestIDs.remove(request.instanceID) }
        }
        if let override = self.responseOverrideForTesting {
            try await override(request, result)
        } else {
            try await self.sendEnvelope(
                JSONRPCEnvelope(id: request.rpcID, result: result)
            )
        }
        guard generation == self.connectionGeneration else { throw CodexOfficialError.connectionChanged }
        self.pendingRequests.removeAll(where: { $0.instanceID == request.instanceID })
    }

    private func sendEnvelope(_ envelope: JSONRPCEnvelope) async throws {
        guard let webSocketTask = self.webSocketTask else {
            throw AppServerClientError.notConnected
        }

        let data = try JSONEncoder().encode(envelope)
        guard let message = String(data: data, encoding: .utf8) else {
            throw AppServerClientError.malformedResponse
        }

        try await webSocketTask.send(.string(message))
    }

    private func startReceiveLoop() {
        self.receiveTask?.cancel()
        let generation = self.connectionGeneration
        self.receiveTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                guard generation == self.connectionGeneration, let webSocketTask = self.webSocketTask else {
                    return
                }

                do {
                    let message = try await webSocketTask.receive()
                    guard !Task.isCancelled, generation == self.connectionGeneration else { return }
                    try await self.handleIncoming(message)
                } catch {
                    if Task.isCancelled || generation != self.connectionGeneration {
                        return
                    }
                    await self.handleSocketFailure(error)
                    return
                }
            }
        }
    }

    private func startPingLoop() {
        self.pingTask?.cancel()
        let generation = self.connectionGeneration
        self.pingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if Task.isCancelled {
                    return
                }
                guard generation == self.connectionGeneration, let webSocketTask = self.webSocketTask else {
                    return
                }

                do {
                    let startedAt = Date()
                    try await webSocketTask.sendPingAsync()
                    guard !Task.isCancelled, generation == self.connectionGeneration else { return }
                    self.markSuccessfulPing(latencyMS: Date().timeIntervalSince(startedAt) * 1000)
                } catch {
                    guard !Task.isCancelled, generation == self.connectionGeneration else { return }
                    await self.handleSocketFailure(error)
                    return
                }
            }
        }
    }

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) async throws {
        self.hasReceivedMessageOnCurrentConnection = true

        let data: Data
        switch message {
        case .data(let binaryData):
            data = binaryData
        case .string(let string):
            guard let encoded = string.data(using: .utf8) else {
                throw AppServerClientError.malformedResponse
            }
            data = encoded
        @unknown default:
            throw AppServerClientError.unsupportedMessage
        }

        let envelope = try JSONDecoder().decode(JSONRPCEnvelope.self, from: data)

        if let method = envelope.method {
            if let requestID = envelope.id {
                self.handleServerRequest(id: requestID, method: method, params: envelope.params)
            } else {
                self.handleNotification(method: method, params: envelope.params)
            }
            return
        }

        guard let responseID = envelope.id else {
            throw AppServerClientError.malformedResponse
        }

        await self.router.resolveResponse(id: responseID, result: envelope.result, error: envelope.error)
    }

    private func handleServerRequest(id: JSONValue, method: String, params: JSONValue?) {
        let parsed = self.parsePendingRequest(id: id, method: method, params: params)
        self.pendingRequests.removeAll(where: { $0.requestIDKey == parsed.requestIDKey })
        self.pendingRequests.append(parsed)
        self.appendEvent("Server request: \(method)")
    }

    private func handleNotification(method: String, params: JSONValue?) {
        if self.handleOfficialNotification(method: method, params: params) { return }
        let paramsObject = params?.objectValue ?? [:]
        if method != "turn/started", method.hasPrefix("turn/") || method.hasPrefix("item/") || method == "thread/tokenUsage/updated",
           let threadID = paramsObject["threadId"]?.stringValue,
           let turnID = Self.findString(in: paramsObject, paths: [["turnId"], ["turn", "id"]]),
           let latest = self.activeTurnIDByThread[threadID] ?? self.latestTurnIDByThread[threadID], latest != turnID {
            // Turn IDs are opaque. An event for another observed turn cannot own the current turn's state.
            return
        }

        switch method {
        case "item/agentMessage/delta", "item/commandExecution/outputDelta":
            guard let threadID = paramsObject["threadId"]?.stringValue,
                  let delta = paramsObject["delta"]?.stringValue
            else {
                return
            }
            let existing = self.transcriptByThread[threadID] ?? ""
            self.transcriptByThread[threadID] = existing + delta
            self.transcriptRevisionByThread[threadID, default: 0] &+= 1
            self.turnStreamingPhaseByThread[threadID] = .responding

        case "item/plan/delta":
            guard let threadID = paramsObject["threadId"]?.stringValue else {
                return
            }
            let itemID = Self.findString(
                in: paramsObject,
                paths: [
                    ["itemId"],
                    ["item", "id"],
                ]
            )
            let delta = Self.findRawString(
                in: paramsObject,
                paths: [
                    ["delta"],
                    ["textDelta"],
                ]
            ) ?? ""
            self.appendStreamedItemDelta(
                threadID: threadID,
                itemID: itemID,
                kind: "plan",
                prefix: "Plan: ",
                delta: delta
            )
            if self.turnStreamingPhaseByThread[threadID] == nil {
                self.turnStreamingPhaseByThread[threadID] = .thinking
            }

        case "item/reasoning/summaryTextDelta":
            guard let threadID = paramsObject["threadId"]?.stringValue else {
                return
            }
            let itemID = Self.findString(
                in: paramsObject,
                paths: [
                    ["itemId"],
                    ["item", "id"],
                ]
            )
            let summaryIndex = Self.findInt(
                in: paramsObject,
                paths: [
                    ["summaryIndex"],
                    ["summary", "index"],
                ]
            ) ?? 0
            let delta = Self.findRawString(
                in: paramsObject,
                paths: [
                    ["delta"],
                    ["textDelta"],
                    ["summaryTextDelta"],
                ]
            ) ?? ""
            self.appendStreamedItemDelta(
                threadID: threadID,
                itemID: itemID,
                kind: "reasoning-\(summaryIndex)",
                prefix: "Reasoning: ",
                delta: delta
            )
            if self.turnStreamingPhaseByThread[threadID] == nil {
                self.turnStreamingPhaseByThread[threadID] = .thinking
            }

        case "item/started":
            guard let threadID = paramsObject["threadId"]?.stringValue else {
                return
            }
            let itemObject = paramsObject["item"]?.objectValue ?? paramsObject
            let itemType = Self.findString(
                in: itemObject,
                paths: [
                    ["type"],
                    ["itemType"],
                    ["item_type"],
                ]
            )?.lowercased() ?? ""
            if itemType.contains("agentmessage") || itemType.contains("agent_message") {
                self.turnStreamingPhaseByThread[threadID] = .responding
            } else if self.turnStreamingPhaseByThread[threadID] == nil {
                self.turnStreamingPhaseByThread[threadID] = .thinking
            }

        case "turn/started":
            if let threadID = paramsObject["threadId"]?.stringValue,
               let turn = paramsObject["turn"]?.objectValue,
               let turnID = turn["id"]?.stringValue {
                self.activeTurnIDByThread[threadID] = turnID
                self.latestTurnIDByThread[threadID] = turnID
                self.turnStateRevisionByThread[threadID, default: 0] &+= 1
                if self.turnStreamingPhaseByThread[threadID] != .responding {
                    self.turnStreamingPhaseByThread[threadID] = .thinking
                }
                self.transcriptSnapshotBeforeTurn[threadID] = self.transcriptByThread[threadID] ?? ""
                self.appendEvent("Turn started for \(threadID)")
            }

        case "turn/completed", "turn/failed", "turn/cancelled":
            guard let threadID = paramsObject["threadId"]?.stringValue else {
                return
            }
            let turn = paramsObject["turn"]?.objectValue ?? [:]
            let completedTurnID = turn["id"]?.stringValue ?? paramsObject["turnId"]?.stringValue
                ?? self.activeTurnIDByThread[threadID]
            self.turnStateRevisionByThread[threadID, default: 0] &+= 1
            if let completedTurnID { self.latestTurnIDByThread[threadID] = completedTurnID }
            let status = turn["status"]?.stringValue
                ?? method.split(separator: "/").last.map(String.init)
                ?? "completed"
            self.appendEvent("Turn \(status) for \(threadID)")

            let fullTranscript = self.transcriptByThread[threadID] ?? ""
            let before = self.transcriptSnapshotBeforeTurn.removeValue(forKey: threadID) ?? ""
            let responseDelta = String(fullTranscript.dropFirst(before.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = responseDelta.count > 200
                ? String(responseDelta.prefix(200)) + "…"
                : responseDelta
            self.onTurnCompleted?(threadID, status, snippet)

            self.activeTurnIDByThread.removeValue(forKey: threadID)
            self.turnStreamingPhaseByThread.removeValue(forKey: threadID)
            if let completedTurnID {
                self.pendingRequests.removeAll(where: { $0.threadID == threadID && $0.turnID == completedTurnID })
            }
            self.clearStreamedItemPrefixKeys(for: threadID)
            self.endBackgroundProcessingIfIdle()

            let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let shouldRefreshThreadSnapshot = method == "turn/completed" || normalizedStatus == "completed"
            if shouldRefreshThreadSnapshot, self.state == .connected {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        _ = try await self.threadRead(threadID: threadID)
                    } catch {
                        self.appendEvent("thread/read after \(method) failed: \(error.localizedDescription)")
                    }
                }
            }

        case "thread/tokenUsage/updated":
            guard let threadID = paramsObject["threadId"]?.stringValue else {
                return
            }
            self.contextUsageByThread[threadID] = Self.parseContextUsage(paramsObject)

        case "thread/status/changed":
            if let threadID = paramsObject["threadId"]?.stringValue, let raw = paramsObject["status"],
               let status = try? self.decode(raw, as: AppServerThreadStatus.self) {
                self.statusRevisionByThread[threadID, default: 0] &+= 1
                self.lastReportedStatusByThread[threadID] = status
                self.threadRecordsByID[threadID]?.status = status
            }

        case "account/rateLimits/updated":
            var parsed = Self.parseRateLimitCatalog(.object(paramsObject))
            if parsed.isEmpty, let data = paramsObject["data"] {
                parsed = Self.parseRateLimitCatalog(data)
            }
            self.rateLimits = parsed
            if let planType = Self.parsePlanType(from: .object(paramsObject)) {
                self.diagnostics.planType = planType
            }

        case "account/updated":
            if let payload = try? self.decode(.object(paramsObject), as: AccountUpdatedNotificationPayload.self) {
                if let authMode = Self.nonEmpty(payload.authMode) {
                    self.diagnostics.authStatus = authMode
                }
                self.diagnostics.planType = Self.nonEmpty(payload.planType)
            }

        case "serverRequest/resolved":
            guard let payload = try? self.decode(.object(paramsObject), as: ServerRequestResolvedNotificationPayload.self),
                  let requestIDKey = AppServerMessageRouter.idKey(from: payload.requestID) else {
                return
            }
            self.pendingRequests.removeAll(where: { $0.requestIDKey == requestIDKey })
            self.lastResolvedPendingRequest = AppServerResolvedPendingRequest(
                threadID: payload.threadID,
                requestIDKey: requestIDKey,
                resolvedAt: Date()
            )

        case "thread/started":
            if let thread = paramsObject["thread"]?.objectValue,
               let threadID = thread["id"]?.stringValue {
                if let metadata = try? self.decode(.object(thread), as: ThreadReadThreadPayload.self) {
                    self.rememberThread(Self.threadRecord(metadata, existing: self.threadRecordsByID[threadID]))
                }
                self.appendEvent("Thread started: \(threadID)")
            }

        case "app/list/updated":
            let rows = paramsObject["data"]?.arrayValue
                ?? paramsObject["apps"]?.arrayValue
                ?? []
            let parsed = Self.parseAppCatalog(rows)
            self.availableApps = parsed.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            self.rebuildSlashCommandCatalog()

        case "error":
            if let message = paramsObject["message"]?.stringValue {
                self.lastErrorMessage = "[Protocol] \(message)"
            }

        default:
            self.appendEvent("Notification: \(method)")
        }
    }

    private func appendStreamedItemDelta(
        threadID: String,
        itemID: String?,
        kind: String,
        prefix: String,
        delta: String
    ) {
        guard !delta.isEmpty else { return }

        let normalizedItemID = Self.nonEmpty(itemID) ?? "unknown"
        let streamKey = "\(threadID)|\(kind)|\(normalizedItemID)"
        var existing = self.transcriptByThread[threadID] ?? ""

        if self.streamedItemPrefixKeys.contains(streamKey) == false {
            if !existing.isEmpty, existing.hasSuffix("\n") == false {
                existing.append("\n")
            }
            existing.append(prefix)
            self.streamedItemPrefixKeys.insert(streamKey)
        }

        existing.append(delta)
        self.transcriptByThread[threadID] = existing
        self.transcriptRevisionByThread[threadID, default: 0] &+= 1
    }

    private func clearStreamedItemPrefixKeys(for threadID: String) {
        self.streamedItemPrefixKeys = self.streamedItemPrefixKeys.filter { key in
            key.hasPrefix("\(threadID)|") == false
        }
    }

    func applyNotificationForTesting(method: String, params: JSONValue?) {
        self.handleNotification(method: method, params: params)
    }

    func applyServerRequestForTesting(id: JSONValue, method: String, params: JSONValue?) {
        self.handleServerRequest(id: id, method: method, params: params)
    }

    func setStateForTesting(_ state: State, host: RemoteHost? = nil) {
        if let host { self.lastHost = host }
        self.transition(to: state)
    }

    func resetSlashCommandCatalogRebuildCountForTesting() {
        self.slashCommandCatalogRebuildCount = 0
    }

    var slashCommandCatalogRebuildCountForTesting: Int {
        self.slashCommandCatalogRebuildCount
    }

    private func parsePendingRequest(id: JSONValue, method: String, params: JSONValue?) -> AppServerPendingRequest {
        let paramsObject = params?.objectValue ?? [:]
        if let official = Self.parseOfficialRequest(id: id, method: method, params: paramsObject) { return official }
        let threadID = Self.findString(in: paramsObject, paths: [["threadId"], ["thread_id"]]) ?? ""
        let turnID = Self.findString(in: paramsObject, paths: [["turnId"], ["turn_id"]]) ?? ""
        let itemID = Self.findString(in: paramsObject, paths: [["itemId"], ["item_id"]]) ?? ""
        let requestIDKey = AppServerMessageRouter.idKey(from: id) ?? UUID().uuidString
        let normalizedMethod = method
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        let kind: AppServerPendingRequestKind
        switch normalizedMethod {
        case "item/commandexecution/requestapproval":
            let command = paramsObject["command"]?.stringValue ?? ""
            let cwd = paramsObject["cwd"]?.stringValue
            let reason = paramsObject["reason"]?.stringValue
            let proposedExecPolicyAmendment = Self.parseExecPolicyAmendment(
                paramsObject["proposedExecpolicyAmendment"]
                    ?? paramsObject["proposed_execpolicy_amendment"]
            )
            let proposedNetworkPolicyAmendments = Self.parseProposedNetworkPolicyAmendments(
                paramsObject["proposedNetworkPolicyAmendments"]
                    ?? paramsObject["proposed_network_policy_amendments"]
            )
            let networkApprovalContext = Self.parseNetworkApprovalContext(
                paramsObject["networkApprovalContext"]
                    ?? paramsObject["network_approval_context"]
            )
            let additionalPermissions = Self.parseAdditionalPermissions(
                paramsObject["additionalPermissions"]
                    ?? paramsObject["additional_permissions"]
            )

            let availableDecisionRows = paramsObject["availableDecisions"]?.arrayValue
                ?? paramsObject["available_decisions"]?.arrayValue
                ?? []
            var availableDecisions = Self.parseAvailableCommandApprovalDecisions(
                availableDecisionRows,
                proposedExecPolicyAmendment: proposedExecPolicyAmendment,
                proposedNetworkPolicyAmendments: proposedNetworkPolicyAmendments
            )
            if availableDecisions.isEmpty {
                availableDecisions = [.accept, .acceptForSession]
                if proposedExecPolicyAmendment != nil {
                    availableDecisions.append(
                        .acceptWithExecpolicyAmendment(amendment: proposedExecPolicyAmendment)
                    )
                }
                if let firstNetworkAmendment = proposedNetworkPolicyAmendments.first {
                    availableDecisions.append(
                        .applyNetworkPolicyAmendment(amendment: firstNetworkAmendment)
                    )
                } else if networkApprovalContext != nil {
                    availableDecisions.append(.applyNetworkPolicyAmendment(amendment: nil))
                }
                availableDecisions.append(contentsOf: [.decline, .cancel])
            }

            kind = .commandApproval(
                command: command,
                cwd: cwd,
                reason: reason,
                availableDecisions: availableDecisions,
                proposedExecPolicyAmendment: proposedExecPolicyAmendment,
                proposedNetworkPolicyAmendments: proposedNetworkPolicyAmendments,
                networkApprovalContext: networkApprovalContext,
                additionalPermissions: additionalPermissions
            )

        case "item/filechange/requestapproval":
            let reason = paramsObject["reason"]?.stringValue
            kind = .fileChange(reason: reason)

        case "tool/requestuserinput", "item/tool/requestuserinput":
            let questions = (paramsObject["questions"]?.arrayValue ?? []).compactMap { rawQuestion -> AppServerUserInputQuestion? in
                guard let questionObject = rawQuestion.objectValue else {
                    return nil
                }

                let questionID = questionObject["id"]?.stringValue
                    ?? questionObject["questionId"]?.stringValue
                    ?? questionObject["name"]?.stringValue
                    ?? questionObject["key"]?.stringValue
                guard let questionID,
                      !questionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    return nil
                }

                let prompt = questionObject["question"]?.stringValue
                    ?? questionObject["prompt"]?.stringValue
                    ?? questionObject["header"]?.stringValue
                    ?? questionObject["title"]?.stringValue
                    ?? "Input required"

                let optionRows = questionObject["options"]?.arrayValue
                    ?? questionObject["choices"]?.arrayValue
                    ?? questionObject["answers"]?.arrayValue

                let options = (optionRows ?? []).compactMap { rawOption -> AppServerUserInputQuestionOption? in
                    guard let optionObject = rawOption.objectValue,
                          let label = optionObject["label"]?.stringValue
                            ?? optionObject["title"]?.stringValue
                            ?? optionObject["value"]?.stringValue
                            ?? optionObject["id"]?.stringValue
                    else {
                        return nil
                    }
                    let description = optionObject["description"]?.stringValue
                        ?? optionObject["helpText"]?.stringValue
                        ?? optionObject["details"]?.stringValue
                        ?? ""
                    return AppServerUserInputQuestionOption(label: label, description: description)
                }

                return AppServerUserInputQuestion(id: questionID, prompt: prompt, options: options)
            }
            kind = .userInput(questions: questions)

        default:
            kind = .unknown
        }

        return AppServerPendingRequest(
            requestIDKey: requestIDKey,
            rpcID: id,
            method: method,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            kind: kind
        )
    }

    private func handleSocketFailure(_ error: Error) async {
        let shouldAttemptReconnect = self.shouldAttemptReconnect(after: error)
        let failureMessage = self.userFacingMessage(for: error)
        let endpoint = self.connectedEndpoint

        self.activeTurnIDByThread.removeAll()
        self.turnStreamingPhaseByThread.removeAll()
        self.streamedItemPrefixKeys.removeAll()
        self.teardownConnection(closeCode: .abnormalClosure)
        self.endBackgroundProcessing()

        guard shouldAttemptReconnect,
              self.autoReconnectEnabled,
              let host = self.lastHost
        else {
            self.transition(to: .failed, endpoint: endpoint, errorMessage: failureMessage)
            return
        }

        self.reconnectAttempts += 1
        self.diagnostics.reconnectAttemptCount = self.reconnectAttempts
        let delaySeconds = Self.reconnectDelaySeconds(
            attempt: self.reconnectAttempts,
            maximumDelaySeconds: self.maxReconnectDelaySeconds
        )
        self.appendEvent(
            "Reconnect attempt \(self.reconnectAttempts) in \(Int(delaySeconds.rounded()))s..."
        )
        self.transition(to: .reconnecting, endpoint: endpoint, errorMessage: failureMessage)

        self.reconnectTask?.cancel()
        let generation = self.connectionGeneration
        self.reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            if Task.isCancelled || generation != self.connectionGeneration || !self.autoReconnectEnabled {
                return
            }

            do {
                try await self.openConnection(to: host, resetReconnectAttempts: false)
            } catch {
                guard !Task.isCancelled, self.autoReconnectEnabled, self.lastHost == host else { return }
                await self.handleSocketFailure(error)
            }
        }
    }

    static func reconnectDelaySeconds(
        attempt: Int,
        maximumDelaySeconds: TimeInterval = 30
    ) -> TimeInterval {
        let normalizedAttempt = max(1, attempt)
        return min(pow(2.0, Double(normalizedAttempt - 1)), maximumDelaySeconds)
    }

    private func teardownConnection(closeCode: URLSessionWebSocketTask.CloseCode) {
        let generation = self.connectionGeneration
        self.connectionGeneration &+= 1
        self.threadRecordsByID.removeAll()
        self.threadGoalsByID.removeAll()
        self.threadPlansByID.removeAll()
        self.threadDiffsByID.removeAll()
        self.threadNamesByID.removeAll()
        self.compactingThreads.removeAll()
        self.unsupportedOfficialMethods.removeAll()
        self.goalRevisionByThread.removeAll()
        self.threadNameRevisionByThread.removeAll()
        self.compactionAcknowledgedThreads.removeAll()
        self.turnStateRevisionByThread.removeAll()
        self.transcriptRevisionByThread.removeAll()
        self.statusRevisionByThread.removeAll()
        self.lastReportedStatusByThread.removeAll()
        self.latestTurnIDByThread.removeAll()
        self.respondingRequestIDs.removeAll()
        self.activeTurnIDByThread.removeAll()
        self.turnStreamingPhaseByThread.removeAll()
        self.transcriptSnapshotBeforeTurn.removeAll()
        self.contextUsageByThread.removeAll()
        self.receiveTask?.cancel()
        self.receiveTask = nil

        self.pingTask?.cancel()
        self.pingTask = nil

        self.webSocketTask?.cancel(with: closeCode, reason: nil)
        self.webSocketTask = nil
        self.hasReceivedMessageOnCurrentConnection = false
        self.pendingRequests.removeAll()
        self.streamedItemPrefixKeys.removeAll()

        Task {
            await self.router.failAll(with: AppServerClientError.notConnected, generation: generation)
        }
    }

    private func measurePingLatency() async throws -> Double {
        guard let webSocketTask = self.webSocketTask else {
            throw AppServerClientError.notConnected
        }

        let startedAt = Date()
        try await webSocketTask.sendPingAsync()
        return Date().timeIntervalSince(startedAt) * 1000
    }

    private func applyInitializeMetadata(from result: JSONValue) {
        guard let object = result.objectValue else {
            return
        }

        if let cliVersion = Self.findString(
            in: object,
            paths: [
                ["serverInfo", "version"],
                ["server", "version"],
                ["cli", "version"],
                ["version"],
            ]
        ) {
            self.diagnostics.cliVersion = cliVersion
        }

        if let authStatus = Self.findString(
            in: object,
            paths: [
                ["authStatus"],
                ["auth", "status"],
                ["session", "authStatus"],
                ["login", "status"],
            ]
        ) {
            self.diagnostics.authStatus = authStatus
        }
        if let planType = Self.parsePlanType(from: .object(object)) {
            self.diagnostics.planType = planType
        }

        if let model = Self.findString(
            in: object,
            paths: [
                ["currentModel"],
                ["model"],
                ["session", "model"],
                ["defaults", "model"],
            ]
        ) {
            self.diagnostics.currentModel = model
        }
    }

    func refreshCatalogs(primaryCWD: String?) async {
        guard self.state == .connected else {
            self.availableSlashCommands = []
            return
        }

        if let overrides = self.catalogRefreshOverrides {
            if let modelCatalog = overrides.modelCatalog {
                self.availableModels = modelCatalog
                if self.nonEmptyOrNil(self.diagnostics.currentModel) == nil,
                   let preferredModel = modelCatalog.first(where: { $0.isDefault })?.model ?? modelCatalog.first?.model {
                    self.diagnostics.currentModel = preferredModel
                }
            }
            self.availableCollaborationModes = overrides.collaborationModes
            self.availableSkills = overrides.skills
            self.availableApps = overrides.apps
            self.rebuildSlashCommandCatalog()
            return
        }

        let generation = self.connectionGeneration
        async let fetchedModels = self.fetchModelCatalog()
        async let fetchedCollaborationModes = self.fetchCollaborationModeCatalog()
        async let fetchedSkills = self.fetchSkillCatalog(primaryCWD: primaryCWD)
        async let fetchedApps = self.fetchAppCatalog()

        let (modelCatalog, collaborationModes, skills, apps) = await (
            fetchedModels,
            fetchedCollaborationModes,
            fetchedSkills,
            fetchedApps
        )
        guard generation == self.connectionGeneration, self.state == .connected else { return }

        if let modelCatalog {
            self.availableModels = modelCatalog
            if self.nonEmptyOrNil(self.diagnostics.currentModel) == nil,
               let preferredModel = modelCatalog.first(where: { $0.isDefault })?.model ?? modelCatalog.first?.model {
                self.diagnostics.currentModel = preferredModel
            }
        }
        self.availableCollaborationModes = collaborationModes
        self.availableSkills = skills
        self.availableApps = apps

        self.rebuildSlashCommandCatalog()
    }

    private func fetchModelCatalog() async -> [AppServerModelDescriptor]? {
        var entries: [ModelListEntryPayload] = []
        var cursor: String?
        var seenCursors: Set<String> = []

        do {
            while true {
                var params: [String: JSONValue] = [
                    "limit": .number(100),
                    "includeHidden": .bool(false),
                ]
                if let cursor {
                    params["cursor"] = .string(cursor)
                }

                let result = try await self.request(method: "model/list", params: .object(params))
                let payload: ModelListResponsePayload = try self.decode(result, as: ModelListResponsePayload.self)
                entries.append(contentsOf: payload.data)

                guard let nextCursor = Self.nonEmpty(payload.nextCursor),
                      !seenCursors.contains(nextCursor),
                      entries.count < 300
                else {
                    break
                }
                seenCursors.insert(nextCursor)
                cursor = nextCursor
            }
        } catch {
            self.appendEvent("model/list unavailable: \(error.localizedDescription)")
            return nil
        }

        let catalog = Self.parseModelCatalog(entries)
        return catalog.isEmpty ? nil : catalog
    }

    private func fetchCollaborationModeCatalog() async -> [AppServerCollaborationModeDescriptor] {
        do {
            let result = try await self.request(method: "collaborationMode/list", params: nil)
            return Self.parseCollaborationModeCatalog(result)
        } catch let AppServerClientError.remote(code, message) where code == -32601 {
            self.appendEvent("collaborationMode/list unavailable: \(message)")
            return []
        } catch {
            self.appendEvent("collaborationMode/list unavailable: \(error.localizedDescription)")
            return []
        }
    }

    private func fetchSkillCatalog(primaryCWD: String?) async -> [AppServerSkillSummary] {
        var params: [String: JSONValue] = [
            "forceReload": .bool(false)
        ]
        if let primaryCWD = Self.nonEmpty(primaryCWD) {
            params["cwds"] = .array([.string(primaryCWD)])
        }

        do {
            let result = try await self.request(method: "skills/list", params: .object(params))
            var entries = Self.dataArray(from: result)
            if entries.isEmpty,
               let object = result.objectValue,
               let directSkills = object["skills"]?.arrayValue {
                entries = [.object(["skills": .array(directSkills)])]
            }
            let parsed = Self.parseSkillCatalog(entries)
            return parsed.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            self.appendEvent("skills/list unavailable: \(error.localizedDescription)")
            return []
        }
    }

    private func fetchAppCatalog() async -> [AppServerAppSummary] {
        var rows: [JSONValue] = []
        var cursor: String?
        var seenCursors: Set<String> = []

        do {
            while true {
                var params: [String: JSONValue] = [
                    "limit": .number(100),
                    "forceRefetch": .bool(false),
                ]
                if let cursor {
                    params["cursor"] = .string(cursor)
                }

                let result = try await self.request(method: "app/list", params: .object(params))
                let pageRows = Self.dataArray(from: result, fallbackKeys: ["apps"])
                rows.append(contentsOf: pageRows)

                guard let nextCursor = Self.nextCursor(from: result),
                      !nextCursor.isEmpty,
                      !seenCursors.contains(nextCursor),
                      rows.count < 300
                else {
                    break
                }

                seenCursors.insert(nextCursor)
                cursor = nextCursor
            }
        } catch {
            self.appendEvent("app/list unavailable: \(error.localizedDescription)")
            return []
        }

        let parsed = Self.parseAppCatalog(rows)
        return parsed.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func rebuildSlashCommandCatalog() {
        self.slashCommandCatalogRebuildCount += 1
        guard self.state == .connected else {
            self.availableSlashCommands = []
            return
        }

        self.availableSlashCommands = [
            AppServerSlashCommandDescriptor(
                kind: .newThread,
                command: "/new",
                title: L10n.text("New Thread"),
                description: L10n.text("Start a new conversation."),
                systemImage: "plus.bubble",
                requiresThread: false
            ),
            AppServerSlashCommandDescriptor(
                kind: .forkThread,
                command: "/fork",
                title: L10n.text("Fork"),
                description: L10n.text("Fork the current thread."),
                systemImage: "arrow.triangle.branch",
                requiresThread: true
            ),
            AppServerSlashCommandDescriptor(
                kind: .startReview,
                command: "/review",
                title: L10n.text("Code review"),
                description: L10n.text("Run reviewer on current changes."),
                systemImage: "checkmark.shield",
                requiresThread: true
            ),
            AppServerSlashCommandDescriptor(
                kind: .startPlanMode,
                command: "/plan",
                title: L10n.text("Plan mode"),
                description: L10n.text("Switch next turns to planning mode."),
                systemImage: "checklist",
                requiresThread: false
            ),
            AppServerSlashCommandDescriptor(
                kind: .showStatus,
                command: "/status",
                title: L10n.text("Status"),
                description: L10n.text("Show connection, model, and catalog status."),
                systemImage: "info.circle",
                requiresThread: false
            ),
            AppServerSlashCommandDescriptor(
                kind: .showMCPStatus,
                command: "/mcp-status",
                title: L10n.text("MCP status"),
                description: L10n.text("Show MCP server availability."),
                systemImage: "shippingbox",
                requiresThread: false
            ),
        ]
    }


    private func appendEvent(_ message: String) {
        self.eventLog.append(message)
        if self.eventLog.count > 200 {
            self.eventLog.removeFirst(self.eventLog.count - 200)
        }
    }
}
