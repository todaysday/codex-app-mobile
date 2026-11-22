import XCTest
@testable import CodexAppMobile

final class CodexOfficialControlsTests: XCTestCase {
    func testAgentTreeUsesParentLinksAndHandlesMissingParentsAndCycles() {
        let threads = [
            Self.agent("child", parent: "root"), Self.agent("grandchild", parent: "child"),
            Self.agent("orphan", parent: "missing"), Self.agent("cycle-a", parent: "cycle-b"),
            Self.agent("cycle-b", parent: "cycle-a"), Self.agent("fork", parent: nil, forkedFrom: "root"),
            Self.agent("child", parent: "root"),
        ]
        let rows = CodexAgentTree.rows(rootID: "root", threads: threads)
        XCTAssertEqual(Set(rows.map(\.id)), Set(["child", "grandchild", "orphan", "cycle-a", "cycle-b"]))
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.first(where: { $0.id == "child" })?.depth, 0)
        XCTAssertEqual(rows.first(where: { $0.id == "grandchild" })?.depth, 1)
        XCTAssertEqual(rows.first(where: { $0.id == "orphan" })?.hasMissingParent, true)
    }

    func testGoalBudgetOmissionAndNullRemainDifferent() throws {
        let unchanged = try CodexOfficialParameters.goalSet(threadID: "t", objective: nil, status: "paused", budget: .unchanged)
        let unlimited = try CodexOfficialParameters.goalSet(threadID: "t", objective: nil, status: nil, budget: .unlimited)
        let limited = try CodexOfficialParameters.goalSet(threadID: "t", objective: "Finish the tests", status: "active", budget: .limit(12000))
        XCTAssertNil(unchanged.objectValue?["tokenBudget"])
        XCTAssertEqual(unlimited.objectValue?["tokenBudget"], .null)
        XCTAssertEqual(limited.objectValue?["tokenBudget"], .number(12000))
        for value in [unchanged, unlimited, limited] {
            XCTAssertEqual(value.objectValue?["origin"], .string("user"))
            XCTAssertEqual(value.objectValue?["threadId"], .string("t"))
        }
        XCTAssertThrowsError(try CodexOfficialParameters.goalSet(threadID: "t", objective: "  ", status: nil, budget: .unchanged))
        XCTAssertThrowsError(try CodexOfficialParameters.goalSet(threadID: "t", objective: nil, status: "invented", budget: .unchanged))
        XCTAssertThrowsError(try CodexOfficialParameters.goalSet(threadID: "t", objective: nil, status: nil, budget: .limit(-1)))
    }

    @MainActor
    func testStableGoalWirePayloadAndNullResponse() async throws {
        let client = AppServerClient()
        client.requestOverrideForTesting = { method, params in
            XCTAssertEqual(method, "thread/goal/get")
            XCTAssertEqual(params?.objectValue?["threadId"], .string("t"))
            return .object(["goal": Self.goal()])
        }
        let goal = try await client.threadGoalGet(threadID: "t")
        XCTAssertEqual(goal?.objective, "Finish mobile controls")
        XCTAssertEqual(goal?.status, "active")
        XCTAssertEqual(goal?.tokensUsed, 450)
        XCTAssertEqual(goal?.timeUsedSeconds, 32)
        XCTAssertEqual(goal?.tokenBudget, 10000)
        client.requestOverrideForTesting = { _, _ in .object(["goal": .null]) }
        let cleared = try await client.threadGoalGet(threadID: "t")
        XCTAssertNil(cleared)
        XCTAssertNil(client.threadGoalsByID["t"])
    }

    @MainActor
    func testLateGoalReadDoesNotOverwriteNewerNotification() async throws {
        let client = AppServerClient()
        client.requestOverrideForTesting = { _, _ in
            _ = client.handleOfficialNotification(method: "thread/goal/updated", params: .object([
                "threadId": .string("t"), "turnId": .null, "goal": Self.goal(objective: "Newer goal", updatedAt: 200),
            ]))
            return .object(["goal": Self.goal(objective: "Old goal", updatedAt: 100)])
        }
        let result = try await client.threadGoalGet(threadID: "t")
        XCTAssertEqual(result?.objective, "Newer goal")
        XCTAssertEqual(client.threadGoalsByID["t"]?.updatedAt, 200)
    }

    @MainActor
    func testGoalClearDoesNotEraseConcurrentReplacement() async throws {
        let client = AppServerClient()
        client.requestOverrideForTesting = { method, params in
            XCTAssertEqual(method, "thread/goal/clear")
            XCTAssertEqual(params?.objectValue?["origin"], .string("user"))
            _ = client.handleOfficialNotification(method: "thread/goal/updated", params: .object([
                "threadId": .string("t"), "goal": Self.goal(objective: "Replacement"),
            ]))
            return .object(["cleared": .bool(true)])
        }
        let cleared = try await client.threadGoalClear(threadID: "t")
        XCTAssertTrue(cleared)
        XCTAssertEqual(client.threadGoalsByID["t"]?.objective, "Replacement")
        _ = client.handleOfficialNotification(method: "thread/goal/cleared", params: .object(["threadId": .string("other")]))
        XCTAssertNotNil(client.threadGoalsByID["t"])
    }

    @MainActor
    func testClearAlreadyMissingGoalRemovesStaleCache() async throws {
        let client = AppServerClient()
        _ = client.handleOfficialNotification(method: "thread/goal/updated", params: .object([
            "threadId": .string("t"), "goal": Self.goal(),
        ]))
        client.requestOverrideForTesting = { _, _ in .object(["cleared": .bool(false)]) }
        let cleared = try await client.threadGoalClear(threadID: "t")
        XCTAssertFalse(cleared)
        XCTAssertNil(client.threadGoalsByID["t"])
    }

    @MainActor
    func testMismatchedGoalThreadIsRejected() async {
        let client = AppServerClient()
        client.requestOverrideForTesting = { _, _ in .object(["goal": Self.goal(threadID: "another")]) }
        do {
            _ = try await client.threadGoalGet(threadID: "t")
            XCTFail("A goal belonging to another thread must not be displayed")
        } catch { XCTAssertNil(client.threadGoalsByID["t"]) }
    }

    @MainActor
    func testUnknownMethodIsCachedButTransientErrorsAreNot() async {
        let client = AppServerClient()
        var requests = 0
        client.requestOverrideForTesting = { _, _ in
            requests += 1
            throw AppServerClientError.remote(code: -32601, message: "Method not found")
        }
        for _ in 0..<2 {
            do { _ = try await client.threadGoalGet(threadID: "t"); XCTFail("Expected unsupported method") }
            catch { XCTAssertTrue(client.unsupportedOfficialMethods.contains("thread/goal/get")) }
        }
        XCTAssertEqual(requests, 1)
        let disconnected = AppServerClient()
        disconnected.requestOverrideForTesting = { _, _ in throw AppServerClientError.notConnected }
        do { _ = try await disconnected.threadGoalGet(threadID: "t"); XCTFail("Expected connection error") }
        catch { XCTAssertTrue(disconnected.unsupportedOfficialMethods.isEmpty) }
    }

    @MainActor
    func testDiffSnapshotsReplaceAndPlansKeepThreadScope() {
        let client = AppServerClient()
        for diff in ["first patch", "new aggregate patch"] {
            _ = client.handleOfficialNotification(method: "turn/diff/updated", params: .object([
                "threadId": .string("t"), "turnId": .string("turn"), "diff": .string(diff),
            ]))
        }
        XCTAssertEqual(client.threadDiffsByID["t"]?.diff, "new aggregate patch")
        _ = client.handleOfficialNotification(method: "turn/plan/updated", params: .object([
            "threadId": .string("other"), "turnId": .string("other-turn"), "explanation": .string("Verify work"),
            "plan": .array([.object(["step": .string("Run tests"), "status": .string("inProgress")])]),
        ]))
        XCTAssertNil(client.threadPlansByID["t"])
        XCTAssertEqual(client.threadPlansByID["other"]?.steps.first?.status, "inProgress")
    }

    @MainActor
    func testLateTurnMetadataCannotReplaceNewerCompletedTurn() {
        let client = AppServerClient()
        client.applyNotificationForTesting(method: "turn/started", params: .object([
            "threadId": .string("t"), "turn": Self.turn("new", status: "inProgress"),
        ]))
        client.applyNotificationForTesting(method: "turn/diff/updated", params: .object([
            "threadId": .string("t"), "turnId": .string("new"), "diff": .string("current aggregate"),
        ]))
        client.applyNotificationForTesting(method: "turn/completed", params: .object([
            "threadId": .string("t"), "turn": Self.turn("new"),
        ]))
        client.applyNotificationForTesting(method: "turn/diff/updated", params: .object([
            "threadId": .string("t"), "turnId": .string("old"), "diff": .string("obsolete patch"),
        ]))
        client.applyNotificationForTesting(method: "turn/plan/updated", params: .object([
            "threadId": .string("t"), "turnId": .string("old"), "plan": .array([]),
        ]))
        XCTAssertEqual(client.threadDiffsByID["t"]?.diff, "current aggregate")
        XCTAssertNil(client.threadPlansByID["t"])
    }

    @MainActor
    func testRenameFailureKeepsConfirmedName() async {
        let client = AppServerClient()
        client.threadNamesByID["t"] = "Confirmed title"
        client.requestOverrideForTesting = { _, _ in throw AppServerClientError.notConnected }
        do { try await client.threadRename(threadID: "t", name: "Unconfirmed title"); XCTFail("Expected error") }
        catch { XCTAssertEqual(client.threadNamesByID["t"], "Confirmed title") }
    }

    @MainActor
    func testRenameResponseDoesNotOverwriteNewerNameNotification() async throws {
        let client = AppServerClient()
        client.threadRecordsByID["t"] = Self.agent("t", parent: nil)
        client.requestOverrideForTesting = { _, _ in
            _ = client.handleOfficialNotification(method: "thread/name/updated", params: .object([
                "threadId": .string("t"), "threadName": .string("Newer title"),
            ]))
            return .object([:])
        }
        try await client.threadRename(threadID: "t", name: "Older title")
        XCTAssertEqual(client.threadNamesByID["t"], "Newer title")
        XCTAssertEqual(client.threadRecordsByID["t"]?.name, "Newer title")
        _ = client.handleOfficialNotification(method: "thread/name/updated", params: .object([
            "threadId": .string("t"), "threadName": .null,
        ]))
        XCTAssertNil(client.threadNamesByID["t"])
        XCTAssertNil(client.threadRecordsByID["t"]?.name)
    }

    @MainActor
    func testCompactionAcknowledgementIsNotCompletion() async throws {
        let client = AppServerClient()
        var compactRequests = 0
        client.requestOverrideForTesting = { method, _ in
            switch method {
            case "thread/read", "thread/resume": return .object(["thread": Self.thread()])
            case "thread/turns/list": return .object(["data": .array([]), "nextCursor": .null])
            case "thread/compact/start": compactRequests += 1; return .object([:])
            default: throw AppServerClientError.remote(code: -32601, message: "Unexpected method")
            }
        }
        try await client.threadCompact(threadID: "t")
        XCTAssertEqual(compactRequests, 1)
        XCTAssertTrue(client.compactingThreads.contains("t"))
        _ = client.handleOfficialNotification(method: "item/completed", params: .object([
            "threadId": .string("t"), "turnId": .string("compact"), "item": .object(["type": .string("contextCompaction")]),
        ]))
        XCTAssertFalse(client.compactingThreads.contains("t"))
    }

    @MainActor
    func testOnlyPostAcknowledgementIdleSnapshotCanRecoverCompactionState() {
        let client = AppServerClient()
        client.compactingThreads.insert("t")
        client.compactionAcknowledgedThreads.insert("t")
        let idle = AppServerThreadStatus(type: "idle", activeFlags: nil)
        client.reconcileOfficialSnapshot(threadID: "t", status: idle, wasCompactionAcknowledged: false)
        XCTAssertTrue(client.compactingThreads.contains("t"))
        client.reconcileOfficialSnapshot(threadID: "t", status: idle, wasCompactionAcknowledged: true)
        XCTAssertFalse(client.compactingThreads.contains("t"))
        XCTAssertFalse(client.compactionAcknowledgedThreads.contains("t"))
    }

    @MainActor
    func testOldCompactionCompletionDoesNotClearNewTurn() {
        let client = AppServerClient()
        client.applyNotificationForTesting(method: "turn/started", params: .object([
            "threadId": .string("t"), "turn": Self.turn("new", status: "inProgress"),
        ]))
        client.compactingThreads.insert("t")
        client.applyNotificationForTesting(method: "item/completed", params: .object([
            "threadId": .string("t"), "turnId": .string("old"),
            "item": .object(["type": .string("contextCompaction")]),
        ]))
        XCTAssertTrue(client.compactingThreads.contains("t"))
        XCTAssertEqual(client.activeTurnID(for: "t"), "new")
    }

    @MainActor
    func testRevertUsesReturnedCursorAndHydratesRetainedHistory() async throws {
        let client = AppServerClient()
        var usedReturnedCursor = false
        var revertRequests = 0
        client.requestOverrideForTesting = { method, params in
            switch method {
            case "thread/read", "thread/resume": return .object(["thread": Self.thread()])
            case "thread/turns/list":
                let retained = params?.objectValue?["cursor"] == .string("retained-cursor")
                if retained {
                    usedReturnedCursor = true
                    XCTAssertEqual(params?.objectValue?["sortDirection"], .string("desc"))
                }
                return .object(["data": .array(retained ? [Self.turn("one")] : [Self.turn("one"), Self.turn("two")]), "nextCursor": .null])
            case "thread/revert":
                revertRequests += 1
                XCTAssertEqual(params?.objectValue?["beforeTurnId"], .string("two"))
                return .object(["thread": Self.thread(), "turnsBackwardsCursor": .string("retained-cursor"), "itemsBackwardsCursor": .null])
            default: throw AppServerClientError.remote(code: -32601, message: "Unexpected method")
            }
        }
        let detail = try await client.threadRevert(threadID: "t", beforeTurnID: "two")
        XCTAssertEqual(revertRequests, 1)
        XCTAssertTrue(usedReturnedCursor)
        XCTAssertEqual(detail.turns.map(\.id), ["one"])
    }

    @MainActor
    func testActiveThreadCannotBeRevertedOrCompacted() async {
        let client = AppServerClient()
        var mutations = 0
        client.requestOverrideForTesting = { method, _ in
            switch method {
            case "thread/read", "thread/resume": return .object(["thread": Self.thread(status: "active")])
            case "thread/turns/list": return .object(["data": .array([Self.turn("one", status: "inProgress")]), "nextCursor": .null])
            default: mutations += 1; return .object([:])
            }
        }
        do { _ = try await client.threadRevert(threadID: "t", beforeTurnID: "one"); XCTFail("Active revert must fail") }
        catch { }
        do { try await client.threadCompact(threadID: "t"); XCTFail("Active compaction must fail") }
        catch { }
        XCTAssertEqual(mutations, 0)
    }

    @MainActor
    func testSubagentQueryHasExplicitKindsAndOnlyAncestorFilter() async throws {
        let client = AppServerClient()
        client.requestOverrideForTesting = { method, params in
            XCTAssertEqual(method, "thread/list")
            XCTAssertEqual(params?.objectValue?["ancestorThreadId"], .string("parent"))
            XCTAssertNil(params?.objectValue?["parentThreadId"])
            XCTAssertEqual(params?.objectValue?["sourceKinds"], .array(CodexAgentTree.sourceKinds.map(JSONValue.string)))
            return .object(["data": .array([]), "nextCursor": .null])
        }
        let rows = try await client.threadDescendants(threadID: "parent")
        XCTAssertTrue(rows.isEmpty)
    }

    private static func goal(threadID: String = "t", objective: String = "Finish mobile controls", updatedAt: Int = 100) -> JSONValue {
        .object(["threadId": .string(threadID), "objective": .string(objective), "status": .string("active"),
                 "tokenBudget": .number(10000), "tokensUsed": .number(450), "timeUsedSeconds": .number(32),
                 "createdAt": .number(1), "updatedAt": .number(Double(updatedAt))])
    }

    private static func agent(_ id: String, parent: String?, forkedFrom: String? = nil) -> RemoteThreadRecord {
        RemoteThreadRecord(id: id, preview: id, updatedAt: Date(timeIntervalSince1970: 1), archived: false,
                           ephemeral: false, cwd: "/workspace/test", model: nil, reasoningEffort: nil,
                           parentThreadID: parent, forkedFromID: forkedFrom)
    }

    private static func thread(status: String = "idle") -> JSONValue {
        .object(["id": .string("t"), "preview": .string("Test thread"), "cwd": .string("/workspace/test"),
                 "createdAt": .number(1), "updatedAt": .number(2), "ephemeral": .bool(false),
                 "historyMode": .string("paginated"), "canAcceptDirectInput": .bool(true),
                 "status": .object(["type": .string(status), "activeFlags": .array([])]), "turns": .array([])])
    }

    private static func turn(_ id: String, status: String = "completed") -> JSONValue {
        .object(["id": .string(id), "status": .string(status), "itemsView": .string("full"), "items": .array([
            .object(["id": .string("message-\(id)"), "type": .string("agentMessage"), "text": .string("Message \(id)")]),
        ])])
    }
}
