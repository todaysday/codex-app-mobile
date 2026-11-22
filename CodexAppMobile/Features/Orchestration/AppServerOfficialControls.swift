import Foundation

extension AppServerClient {
    func officialRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        guard !unsupportedOfficialMethods.contains(method) else { throw CodexOfficialError.unsupported(method) }
        let generation = connectionGeneration
        do {
            let response = try await request(method: method, params: params)
            guard generation == connectionGeneration else { throw CodexOfficialError.connectionChanged }
            return response
        } catch let error as AppServerClientError {
            if case .remote(let code, _) = error, code == -32601, generation == connectionGeneration {
                unsupportedOfficialMethods.insert(method)
                throw CodexOfficialError.unsupported(method)
            }
            throw error
        }
    }

    func threadGoalGet(threadID: String) async throws -> CodexThreadGoal? {
        let revision = goalRevisionByThread[threadID, default: 0]
        let response = try await officialRequest(method: "thread/goal/get", params: .object(["threadId": .string(threadID)]))
        guard let raw = response.objectValue?["goal"] else { throw AppServerClientError.malformedResponse }
        let goal = try decodeGoal(raw, threadID: threadID)
        if goalRevisionByThread[threadID, default: 0] == revision {
            threadGoalsByID[threadID] = goal
        }
        return threadGoalsByID[threadID]
    }

    func threadGoalSet(
        threadID: String, objective: String? = nil, status: String? = nil,
        budget: CodexGoalBudgetChange = .unchanged
    ) async throws -> CodexThreadGoal {
        try requireDirectControl(threadID)
        let params = try CodexOfficialParameters.goalSet(threadID: threadID, objective: objective, status: status, budget: budget)
        let revision = goalRevisionByThread[threadID, default: 0]
        let response = try await officialRequest(method: "thread/goal/set", params: params)
        guard let raw = response.objectValue?["goal"], let goal = try decodeGoal(raw, threadID: threadID) else {
            throw AppServerClientError.malformedResponse
        }
        if goalRevisionByThread[threadID, default: 0] == revision {
            threadGoalsByID[threadID] = goal
            goalRevisionByThread[threadID, default: 0] += 1
        }
        return goal
    }

    func threadGoalClear(threadID: String) async throws -> Bool {
        try requireDirectControl(threadID)
        let revision = goalRevisionByThread[threadID, default: 0]
        let response = try await officialRequest(method: "thread/goal/clear", params: .object([
            "threadId": .string(threadID), "origin": .string("user"),
        ]))
        guard let cleared = response.objectValue?["cleared"]?.boolValue else {
            throw AppServerClientError.malformedResponse
        }
        if goalRevisionByThread[threadID, default: 0] == revision {
            threadGoalsByID.removeValue(forKey: threadID)
            goalRevisionByThread[threadID, default: 0] += 1
        }
        return cleared
    }

    func threadRename(threadID: String, name: String) async throws {
        try requireDirectControl(threadID)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CodexOfficialError.invalidInput("Enter a thread name.") }
        let revision = threadNameRevisionByThread[threadID, default: 0]
        _ = try await officialRequest(method: "thread/name/set", params: .object([
            "threadId": .string(threadID), "name": .string(name),
        ]))
        if threadNameRevisionByThread[threadID, default: 0] == revision {
            threadNamesByID[threadID] = name
            threadRecordsByID[threadID]?.name = name
            threadNameRevisionByThread[threadID, default: 0] += 1
        }
    }

    func threadCompact(threadID: String) async throws {
        _ = try await prepareIdleThread(threadID: threadID, requirePaginated: false)
        let generation = connectionGeneration
        compactingThreads.insert(threadID)
        do {
            _ = try await officialRequest(method: "thread/compact/start", params: .object(["threadId": .string(threadID)]))
            // The empty acknowledgement is not a completed compaction. Lifecycle events clear this state.
            if compactingThreads.contains(threadID) { compactionAcknowledgedThreads.insert(threadID) }
        } catch {
            if generation == connectionGeneration {
                compactingThreads.remove(threadID)
                compactionAcknowledgedThreads.remove(threadID)
            }
            throw error
        }
    }

    func threadRevert(threadID: String, beforeTurnID: String) async throws -> CodexThreadDetail {
        let detail = try await prepareIdleThread(threadID: threadID, requirePaginated: true)
        guard detail.turns.contains(where: { $0.id == beforeTurnID }) else {
            throw CodexOfficialError.invalidInput("This turn is no longer in the current history. Refresh and choose it again.")
        }
        let response = try await officialRequest(method: "thread/revert", params: .object([
            "threadId": .string(threadID), "beforeTurnId": .string(beforeTurnID),
        ]))
        guard response.objectValue?["thread"]?.objectValue?["id"]?.stringValue == threadID else {
            throw AppServerClientError.malformedResponse
        }
        let cursor = response.objectValue?["turnsBackwardsCursor"]?.stringValue
        // Revert responses deliberately have no turns. Hydrate retained history from its actual cursor.
        return try await threadRead(threadID: threadID, turnsCursor: cursor, turnsSortDirection: "desc")
    }

    func threadDescendants(threadID: String) async throws -> [RemoteThreadRecord] {
        let feature = "thread/list.relationships"
        guard !unsupportedOfficialMethods.contains(feature) else { throw CodexOfficialError.unsupported(feature) }
        let generation = connectionGeneration
        do {
            return try await threadList(ancestorThreadID: threadID, sourceKinds: CodexAgentTree.sourceKinds)
        } catch let error as AppServerClientError {
            guard generation == connectionGeneration else { throw CodexOfficialError.connectionChanged }
            if case .remote(let code, let message) = error,
               code == -32601 || ((code == -32600 || code == -32602) && message.lowercased().contains("experimental")) {
                unsupportedOfficialMethods.insert(feature)
                throw CodexOfficialError.unsupported(feature)
            }
            throw error
        }
    }

    func threadChildren(threadID: String) async throws -> [RemoteThreadRecord] {
        try await threadList(parentThreadID: threadID, sourceKinds: CodexAgentTree.sourceKinds)
    }

    /// A later, accepted idle snapshot can recover from a missed terminal notification.
    /// A snapshot already in flight when compaction was submitted cannot complete it.
    func reconcileOfficialSnapshot(threadID: String, status: AppServerThreadStatus?, wasCompactionAcknowledged: Bool) {
        if wasCompactionAcknowledged, compactionAcknowledgedThreads.contains(threadID),
           status?.type == "idle", activeTurnID(for: threadID) == nil {
            compactingThreads.remove(threadID)
            compactionAcknowledgedThreads.remove(threadID)
        }
    }

    private func prepareIdleThread(threadID: String, requirePaginated: Bool) async throws -> CodexThreadDetail {
        var detail = try await ensureSafeThreadSnapshot(threadID: threadID)
        if threadRecordsByID[threadID]?.status?.type == "notLoaded" {
            detail = try await threadResume(threadID: threadID)
        }
        try requireDirectControl(threadID)
        guard activeTurnID(for: threadID) == nil,
              threadRecordsByID[threadID]?.status?.type == "idle",
              !compactingThreads.contains(threadID) else { throw CodexOfficialError.threadBusy }
        if requirePaginated {
            guard !detail.ephemeral, threadRecordsByID[threadID]?.historyMode == "paginated" else {
                throw CodexOfficialError.historyUnavailable
            }
        }
        return detail
    }

    private func requireDirectControl(_ threadID: String) throws {
        guard !threadID.isEmpty else { throw CodexOfficialError.invalidInput("Select a thread first.") }
        if threadRecordsByID[threadID]?.canAcceptDirectInput == false { throw CodexOfficialError.readOnlyThread }
    }

    private func decodeGoal(_ raw: JSONValue, threadID: String) throws -> CodexThreadGoal? {
        if raw == .null { return nil }
        let goal = try decode(raw, as: CodexThreadGoal.self)
        guard goal.threadID == threadID else { throw AppServerClientError.malformedResponse }
        return goal
    }

    /// Return false for shared lifecycle messages so the base streaming handler still receives them.
    func handleOfficialNotification(method: String, params: JSONValue?) -> Bool {
        guard let values = params?.objectValue, let threadID = values["threadId"]?.stringValue else { return false }
        switch method {
        case "thread/goal/updated":
            if let raw = values["goal"], let goal = try? decodeGoal(raw, threadID: threadID) {
                threadGoalsByID[threadID] = goal
                goalRevisionByThread[threadID, default: 0] += 1
            }
            return true
        case "thread/goal/cleared":
            threadGoalsByID.removeValue(forKey: threadID)
            goalRevisionByThread[threadID, default: 0] += 1
            return true
        case "thread/name/updated":
            threadNamesByID[threadID] = values["threadName"]?.stringValue
            threadRecordsByID[threadID]?.name = values["threadName"]?.stringValue
            threadNameRevisionByThread[threadID, default: 0] += 1
            return true
        case "turn/plan/updated":
            if let params, let plan = try? decode(params, as: CodexThreadPlan.self), acceptsTurnMetadata(threadID, turnID: plan.turnID) {
                threadPlansByID[threadID] = plan
            }
            return true
        case "turn/diff/updated":
            if let params, let diff = try? decode(params, as: CodexThreadDiff.self), acceptsTurnMetadata(threadID, turnID: diff.turnID) {
                threadDiffsByID[threadID] = diff
            }
            return true
        case "turn/started":
            let turnID = values["turn"]?.objectValue?["id"]?.stringValue
            if threadPlansByID[threadID]?.turnID != turnID { threadPlansByID.removeValue(forKey: threadID) }
            if threadDiffsByID[threadID]?.turnID != turnID { threadDiffsByID.removeValue(forKey: threadID) }
        case "turn/completed", "turn/failed", "turn/cancelled":
            if let turnID = values["turn"]?.objectValue?["id"]?.stringValue,
               acceptsTurnMetadata(threadID, turnID: turnID) {
                compactingThreads.remove(threadID)
                compactionAcknowledgedThreads.remove(threadID)
            }
        case "thread/status/changed":
            if values["status"]?.objectValue?["type"]?.stringValue == "idle", activeTurnID(for: threadID) == nil {
                compactingThreads.remove(threadID)
                compactionAcknowledgedThreads.remove(threadID)
            }
        case "thread/compacted":
            compactingThreads.remove(threadID)
            compactionAcknowledgedThreads.remove(threadID)
        case "item/started", "item/completed":
            if values["item"]?.objectValue?["type"]?.stringValue == "contextCompaction" {
                if let turnID = values["turnId"]?.stringValue, !acceptsTurnMetadata(threadID, turnID: turnID) { return false }
                if method == "item/started" { compactingThreads.insert(threadID) }
                else {
                    compactingThreads.remove(threadID)
                    compactionAcknowledgedThreads.remove(threadID)
                }
            }
        default: break
        }
        return false
    }

    private func acceptsTurnMetadata(_ threadID: String, turnID: String) -> Bool {
        if let latest = latestTurnIDByThread[threadID], latest != turnID { return false }
        if let active = activeTurnID(for: threadID), active != turnID { return false }
        return true
    }
}
