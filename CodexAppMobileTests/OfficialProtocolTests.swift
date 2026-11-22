import XCTest
@testable import CodexAppMobile

/// Wire contracts from openai/codex rust-v0.171.0, ccf9be8cc458bd6b8336fe84d68d8893f2691a5e:
/// app-server-protocol/src/protocol/v2/{thread,thread_data,turn,model}.rs.
/// These fixtures exercise client behavior without a server, account, or device connection.
final class OfficialProtocolTests: XCTestCase {
    @MainActor
    func testThreadListLoadsPastOneHundredAndDeduplicatesIDs() async throws {
        let client = AppServerClient()
        var pages = 0
        client.requestOverrideForTesting = { method, params in
            XCTAssertEqual(method, "thread/list")
            XCTAssertEqual(params?["limit"], .number(100))
            XCTAssertEqual(params?["archived"], .bool(true))
            XCTAssertEqual(params?["sourceKinds"], .array(AppServerClient.allThreadSourceKinds.map(JSONValue.string)))
            pages += 1
            if pages == 1 {
                XCTAssertNil(params?["cursor"])
                return Self.page((0..<100).map { Self.thread("thread-\($0)") }, cursor: "next-page")
            }
            XCTAssertEqual(params?["cursor"], .string("next-page"))
            return Self.page([Self.thread("thread-99", updatedAt: 200), Self.thread("thread-100")])
        }
        let records = try await client.threadList(archived: true, limit: 300)
        XCTAssertEqual(pages, 2)
        XCTAssertEqual(records.count, 101)
        XCTAssertEqual(records.last?.id, "thread-100")
        XCTAssertEqual(records.first(where: { $0.id == "thread-99" })?.updatedAt, Date(timeIntervalSince1970: 200))
        XCTAssertTrue(records.allSatisfy(\.archived))
        XCTAssertEqual(client.threadRecordsByID.count, 101)
    }

    @MainActor
    func testRelationshipAndSourceFiltersRemainOnEveryPage() async throws {
        let client = AppServerClient()
        var pages = 0
        client.requestOverrideForTesting = { _, params in
            XCTAssertEqual(params?["parentThreadId"], .string("parent"))
            XCTAssertNil(params?["ancestorThreadId"])
            XCTAssertEqual(params?["sourceKinds"], .array([.string("subAgentThreadSpawn")]))
            pages += 1
            return Self.page([Self.thread("child-\(pages)")], cursor: pages == 1 ? "children-2" : nil)
        }
        let records = try await client.threadList(parentThreadID: "parent", sourceKinds: ["subAgentThreadSpawn"])
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(pages, 2)
    }

    @MainActor
    func testMutuallyExclusiveFiltersAreRejectedBeforeRequest() async {
        let client = AppServerClient()
        client.requestOverrideForTesting = { _, _ in XCTFail("Conflicting filters must not be sent"); return .null }
        do {
            _ = try await client.threadList(parentThreadID: "parent", ancestorThreadID: "ancestor")
            XCTFail("Expected invalid filters")
        } catch {
            guard case AppServerClientError.invalidThreadFilters = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    @MainActor
    func testUnsupportedExplicitFilterNeverBecomesUnfilteredQuery() async {
        let client = AppServerClient()
        var requests = 0
        client.requestOverrideForTesting = { _, _ in
            requests += 1
            throw AppServerClientError.remote(code: -32602, message: "Unsupported sourceKinds")
        }
        for kind in 0..<3 {
            do {
                _ = try await client.threadList(parentThreadID: kind == 0 ? "parent" : nil,
                                                ancestorThreadID: kind == 1 ? "ancestor" : nil,
                                                sourceKinds: kind == 2 ? ["exec"] : nil)
                XCTFail("An explicit unavailable filter must report an error")
            } catch { }
        }
        XCTAssertEqual(requests, 3)
    }

    @MainActor
    func testLegacyDefaultSourceFallbackIsNarrowAndVisible() async throws {
        let client = AppServerClient()
        var requests = 0
        client.requestOverrideForTesting = { _, params in
            requests += 1
            if requests == 1 { throw AppServerClientError.remote(code: -32602, message: "Unknown field sourceKinds") }
            XCTAssertNil(params?["sourceKinds"])
            return Self.page([Self.thread("legacy")])
        }
        let records = try await client.threadList()
        XCTAssertEqual(records.map(\.id), ["legacy"])
        XCTAssertTrue(client.eventLog.contains(where: { $0.contains("legacy interactive sources") }))
        XCTAssertFalse(AppServerClient.isUnsupportedSourceKinds(AppServerClientError.remote(code: 401, message: "sourceKinds requires authentication")))
        XCTAssertFalse(AppServerClient.isUnsupportedSourceKinds(AppServerClientError.remote(code: -32602, message: "Invalid cursor")))
    }

    @MainActor
    func testRepeatedOrFailedPageRetainsPreviouslyLoadedMetadata() async throws {
        let client = AppServerClient()
        client.requestOverrideForTesting = { _, _ in Self.page([Self.thread("saved")]) }
        _ = try await client.threadList()
        for failWithError in [false, true] {
            var pages = 0
            client.requestOverrideForTesting = { _, _ in
                pages += 1
                if failWithError && pages == 2 { throw AppServerClientError.timeout(method: "thread/list") }
                return Self.page([Self.thread("partial-\(pages)")], cursor: "repeated")
            }
            do { _ = try await client.threadList(); XCTFail("Incomplete pagination must be reported") }
            catch { XCTAssertEqual(Set(client.threadRecordsByID.keys), Set(["saved"])) }
            XCTAssertEqual(pages, 2)
        }
    }

    @MainActor
    func testLoadedThreadIDsHaveTheirOwnPagination() async throws {
        let client = AppServerClient()
        var pages = 0
        client.requestOverrideForTesting = { method, params in
            XCTAssertEqual(method, "thread/loaded/list")
            pages += 1
            if pages == 1 { return Self.page([.string("one"), .string("two")], cursor: "loaded-next") }
            XCTAssertEqual(params?["cursor"], .string("loaded-next"))
            return Self.page([.string("two"), .string("three")])
        }
        let ids = try await client.threadLoadedList()
        XCTAssertEqual(ids, ["one", "two", "three"])
        XCTAssertEqual(pages, 2)
    }

    @MainActor
    func testOfficialThreadMetadataRemainsAvailableToChildInspector() async throws {
        let client = AppServerClient()
        let response = try Self.wire("""
        {"data":[{"id":"child","preview":"Review changes","updatedAt":1700000000,"cwd":"/workspace/project",
          "ephemeral":false,"model":"server-model","reasoningEffort":"high","name":"Reviewer",
          "parentThreadId":"parent","forkedFromId":"fork-origin","agentNickname":"Ada","agentRole":"reviewer",
          "status":{"type":"active","activeFlags":["waitingOnApproval"]},"canAcceptDirectInput":false,
          "historyMode":"paginated","source":{"subAgent":"review"}}],"nextCursor":null}
        """)
        client.requestOverrideForTesting = { _, _ in response }
        let records = try await client.threadList()
        let child = try XCTUnwrap(records.first)
        XCTAssertEqual(child.parentThreadID, "parent")
        XCTAssertEqual(child.forkedFromID, "fork-origin")
        XCTAssertEqual(child.name, "Reviewer")
        XCTAssertEqual(child.agentNickname, "Ada")
        XCTAssertEqual(child.agentRole, "reviewer")
        XCTAssertEqual(child.status?.activeFlags, ["waitingOnApproval"])
        XCTAssertEqual(child.canAcceptDirectInput, false)
        XCTAssertEqual(child.historyMode, "paginated")
        XCTAssertNotNil(child.source)
        client.applyNotificationForTesting(method: "thread/status/changed", params: .object([
            "threadId": .string("child"), "status": .object(["type": .string("idle")]),
        ]))
        XCTAssertEqual(client.threadRecordsByID["child"]?.status?.type, "idle")
    }

    @MainActor
    func testMetadataReadHydratesAllFullTurnPagesAndRestoresActiveTurn() async throws {
        let client = AppServerClient()
        var methods: [String] = []
        client.requestOverrideForTesting = { method, params in
            methods.append(method)
            if method == "thread/read" {
                XCTAssertEqual(params?["includeTurns"], .bool(false))
                return .object(["thread": Self.thread("t", status: "active")])
            }
            XCTAssertEqual(method, "thread/turns/list")
            XCTAssertEqual(params?["threadId"], .string("t"))
            XCTAssertEqual(params?["itemsView"], .string("full"))
            XCTAssertEqual(params?["sortDirection"], .string("asc"))
            if params?["cursor"] == nil { return Self.page([Self.turn("old")], cursor: "turn-next") }
            XCTAssertEqual(params?["cursor"], .string("turn-next"))
            return Self.page([Self.turn("live", status: "inProgress", text: "Working")])
        }
        let detail = try await client.threadRead(threadID: "t")
        XCTAssertEqual(detail.turns.map(\.id), ["old", "live"])
        XCTAssertEqual(methods, ["thread/read", "thread/turns/list", "thread/turns/list"])
        XCTAssertEqual(client.activeTurnID(for: "t"), "live")
        XCTAssertEqual(client.latestTurnIDByThread["t"], "live")
        XCTAssertTrue(client.transcriptByThread["t"]?.contains("Working") == true)
    }

    @MainActor
    func testResumeAttachesWithoutStartingThreadOrTurn() async throws {
        let client = AppServerClient()
        var methods: [String] = []
        client.requestOverrideForTesting = { method, params in
            methods.append(method)
            if method == "thread/resume" {
                XCTAssertEqual(params?["excludeTurns"], .bool(true))
                return .object(["thread": Self.thread("t", status: "active"), "model": .string("configured")])
            }
            XCTAssertEqual(method, "thread/turns/list")
            return Self.page([Self.turn("live", status: "inProgress")])
        }
        let detail = try await client.threadResume(threadID: "t")
        XCTAssertEqual(methods, ["thread/resume", "thread/turns/list"])
        XCTAssertEqual(detail.model, "configured")
        XCTAssertEqual(client.activeTurnID(for: "t"), "live")
    }

    @MainActor
    func testOlderResumeCanExplicitlyRejectMetadataOnlyFlag() async throws {
        let client = AppServerClient()
        var calls = 0
        client.requestOverrideForTesting = { method, params in
            XCTAssertEqual(method, "thread/resume")
            calls += 1
            if params?["excludeTurns"] != nil {
                throw AppServerClientError.remote(code: -32602, message: "Unknown field excludeTurns")
            }
            return .object(["thread": Self.thread("t", historyMode: nil, turns: [Self.turn("live", status: "inProgress")])])
        }
        _ = try await client.threadResume(threadID: "t")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(client.activeTurnID(for: "t"), "live")
    }

    @MainActor
    func testRevertedHistoryUsesReturnedCursorAndDescendingOrder() async throws {
        let client = AppServerClient()
        var cursors: [String?] = []
        client.requestOverrideForTesting = { method, params in
            if method == "thread/read" { return .object(["thread": Self.thread("t")]) }
            XCTAssertEqual(method, "thread/turns/list")
            XCTAssertEqual(params?["sortDirection"], .string("desc"))
            XCTAssertEqual(params?["itemsView"], .string("full"))
            cursors.append(params?["cursor"]?.stringValue)
            if cursors.count == 1 { return Self.page([Self.turn("retained-2")], cursor: "older") }
            return Self.page([Self.turn("retained-1")])
        }
        let detail = try await client.threadRead(threadID: "t", turnsCursor: "returned-anchor", turnsSortDirection: "desc")
        XCTAssertEqual(cursors, ["returned-anchor", "older"])
        XCTAssertEqual(detail.turns.map(\.id), ["retained-1", "retained-2"])
    }

    @MainActor
    func testSummaryItemsAndRepeatedHistoryCursorDoNotEraseTranscript() async {
        for summaryItems in [true, false] {
            let client = AppServerClient()
            client.appendLocalEcho("Keep this useful content", to: "t")
            let before = client.transcriptByThread["t"]
            var pages = 0
            client.requestOverrideForTesting = { method, _ in
                if method == "thread/read" { return .object(["thread": Self.thread("t")]) }
                pages += 1
                if summaryItems {
                    return Self.page([.object(["id": .string("summary"), "status": .string("completed"),
                                               "items": .array([]), "itemsView": .string("summary")])])
                }
                return Self.page([Self.turn("turn-\(pages)")], cursor: "repeated")
            }
            do { _ = try await client.threadRead(threadID: "t"); XCTFail("Incomplete history is not an empty conversation") }
            catch {
                guard case AppServerClientError.incompleteHistory = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(client.transcriptByThread["t"], before)
            }
            XCTAssertEqual(pages, summaryItems ? 1 : 2)
        }
    }

    @MainActor
    func testPaginationFallsBackOnlyForUnknownMethod() async throws {
        let client = AppServerClient()
        var calls: [String] = []
        client.requestOverrideForTesting = { method, params in
            calls.append(method)
            if method == "thread/turns/list" { throw AppServerClientError.remote(code: -32601, message: "Method not found") }
            let turns = params?["includeTurns"] == .bool(true) ? [Self.turn("legacy-turn")] : []
            return .object(["thread": Self.thread("t", turns: turns)])
        }
        let detail = try await client.threadRead(threadID: "t")
        XCTAssertEqual(detail.turns.map(\.id), ["legacy-turn"])
        XCTAssertEqual(calls, ["thread/read", "thread/turns/list", "thread/read"])
        XCTAssertTrue(client.unsupportedOfficialMethods.contains("thread/turns/list"))

        let denied = AppServerClient()
        var fullReads = 0
        denied.requestOverrideForTesting = { method, params in
            if method == "thread/turns/list" { throw AppServerClientError.remote(code: 401, message: "Authentication required") }
            if params?["includeTurns"] == .bool(true) { fullReads += 1 }
            return .object(["thread": Self.thread("t")])
        }
        do { _ = try await denied.threadRead(threadID: "t"); XCTFail("Authentication failure must surface") }
        catch { XCTAssertTrue(denied.unsupportedOfficialMethods.isEmpty) }
        XCTAssertEqual(fullReads, 0)
    }

    @MainActor
    func testLegacyMetadataWithoutHistoryModeUsesFullRead() async throws {
        let client = AppServerClient()
        var calls = 0
        client.requestOverrideForTesting = { method, params in
            XCTAssertEqual(method, "thread/read")
            calls += 1
            let turns = params?["includeTurns"] == .bool(true) ? [Self.turn("legacy", status: "inProgress")] : []
            return .object(["thread": Self.thread("t", historyMode: nil, turns: turns)])
        }
        _ = try await client.threadRead(threadID: "t")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(client.activeTurnID(for: "t"), "legacy")
    }

    @MainActor
    func testMismatchedThreadAndChangedConnectionCannotHydrateCache() async {
        for changesConnection in [false, true] {
            let client = AppServerClient()
            var calls = 0
            client.requestOverrideForTesting = { [weak client] _, _ in
                calls += 1
                if changesConnection { client?.disconnect() }
                return .object(["thread": Self.thread(changesConnection ? "t" : "another")])
            }
            do { _ = try await client.threadRead(threadID: "t"); XCTFail("A stale or mismatched response must fail") }
            catch { XCTAssertTrue(client.threadRecordsByID.isEmpty) }
            XCTAssertEqual(calls, 1)
        }
    }

    @MainActor
    func testOlderSnapshotCannotReplaceNewTurnOrLiveText() async throws {
        let client = AppServerClient()
        client.requestOverrideForTesting = { [weak client] method, _ in
            if method == "thread/read" { return .object(["thread": Self.thread("t")]) }
            client?.applyNotificationForTesting(method: "turn/started", params: Self.turnEvent("new", status: "inProgress"))
            client?.applyNotificationForTesting(method: "item/agentMessage/delta", params: .object([
                "threadId": .string("t"), "turnId": .string("new"), "delta": .string("New streamed content"),
            ]))
            return Self.page([Self.turn("old")])
        }
        _ = try await client.threadRead(threadID: "t")
        XCTAssertEqual(client.activeTurnID(for: "t"), "new")
        XCTAssertEqual(client.transcriptByThread["t"], "New streamed content")
    }

    @MainActor
    func testStreamDuringReattachPreservesDeltaAndRestoresTurnIdentity() async throws {
        let client = AppServerClient()
        client.requestOverrideForTesting = { [weak client] method, _ in
            if method == "thread/read" { return .object(["thread": Self.thread("t", status: "active")]) }
            client?.applyNotificationForTesting(method: "item/agentMessage/delta", params: .object([
                "threadId": .string("t"), "turnId": .string("live"), "delta": .string("A newer delta"),
            ]))
            return Self.page([Self.turn("live", status: "inProgress", text: "Earlier response")])
        }
        _ = try await client.threadRead(threadID: "t")
        XCTAssertEqual(client.activeTurnID(for: "t"), "live")
        XCTAssertEqual(client.transcriptByThread["t"], "A newer delta")
    }

    @MainActor
    func testInterruptAcknowledgementAndLateCompletionKeepCurrentOwnership() async throws {
        let client = AppServerClient()
        client.applyNotificationForTesting(method: "turn/started", params: Self.turnEvent("current", status: "inProgress"))
        client.applyServerRequestForTesting(id: .number(77), method: "item/fileChange/requestApproval", params: .object([
            "threadId": .string("t"), "turnId": .string("current"), "itemId": .string("edit"),
        ]))
        client.requestOverrideForTesting = { method, params in
            XCTAssertEqual(method, "turn/interrupt")
            XCTAssertEqual(params?["turnId"], .string("current"))
            return .object([:])
        }
        try await client.turnInterrupt(threadID: "t", turnID: "current")
        XCTAssertEqual(client.activeTurnID(for: "t"), "current")
        client.applyNotificationForTesting(method: "turn/completed", params: Self.turnEvent("older", status: "completed"))
        XCTAssertEqual(client.activeTurnID(for: "t"), "current")
        XCTAssertEqual(client.pendingRequests.map(\.requestIDKey), ["77"])
        client.applyNotificationForTesting(method: "turn/completed", params: Self.turnEvent("current", status: "interrupted"))
        XCTAssertNil(client.activeTurnID(for: "t"))
        XCTAssertEqual(client.latestTurnIDByThread["t"], "current")
        XCTAssertTrue(client.pendingRequests.isEmpty)
    }

    @MainActor
    func testReadOnlyCapabilityGuardsStartAndSteerOutsideUI() async throws {
        let client = AppServerClient()
        client.requestOverrideForTesting = { _, _ in Self.page([Self.thread("child", canAcceptDirectInput: false)]) }
        _ = try await client.threadList()
        client.requestOverrideForTesting = { _, _ in XCTFail("Read-only thread cannot send direct input"); return .null }
        do { _ = try await client.turnStart(threadID: "child", inputText: "Run", model: nil, effort: nil); XCTFail("Expected read-only guard") }
        catch { guard case AppServerClientError.readOnlyThread = error else { return XCTFail("Unexpected error: \(error)") } }
        do { try await client.turnSteer(threadID: "child", expectedTurnID: "live", inputText: "Change"); XCTFail("Expected read-only guard") }
        catch { guard case AppServerClientError.readOnlyThread = error else { return XCTFail("Unexpected error: \(error)") } }
    }

    @MainActor
    func testOfficialUsageKeepsLatestAndCumulativeCountersSeparate() throws {
        let client = AppServerClient()
        let payload = try Self.wire("""
        {"threadId":"t","turnId":"turn","tokenUsage":{
          "last":{"totalTokens":140,"inputTokens":120,"cachedInputTokens":80,"cacheWriteInputTokens":10,"outputTokens":20,"reasoningOutputTokens":5},
          "total":{"totalTokens":10000,"inputTokens":9000,"cachedInputTokens":8000,"cacheWriteInputTokens":500,"outputTokens":1000,"reasoningOutputTokens":300},
          "modelContextWindow":400}}
        """)
        client.applyNotificationForTesting(method: "thread/tokenUsage/updated", params: payload)
        let usage = try XCTUnwrap(client.contextUsage(for: "t"))
        XCTAssertEqual(usage.usedTokens, 140)
        XCTAssertEqual(usage.maxTokens, 400)
        XCTAssertEqual(usage.remainingPercent, 65)
        XCTAssertEqual(usage.lastUsage?.inputTokens, 120)
        XCTAssertEqual(usage.totalUsage?.inputTokens, 9000)
        XCTAssertEqual(usage.totalUsage?.cachedInputTokens, 8000)
        XCTAssertEqual(usage.totalUsage?.cacheWriteInputTokens, 500)
        XCTAssertEqual(usage.totalUsage?.outputTokens, 1000)
        XCTAssertEqual(usage.totalUsage?.reasoningOutputTokens, 300)
    }

    @MainActor
    func testUnknownWindowAndMissingLatestCountsStayUnknown() throws {
        let raw = try Self.wire("""
        {"tokenUsage":{"last":{"totalTokens":140,"inputTokens":120,"cachedInputTokens":80,"outputTokens":20,"reasoningOutputTokens":5},
                       "total":{"totalTokens":10000},"modelContextWindow":null}}
        """)
        let usage = AppServerClient.parseContextUsage(try XCTUnwrap(raw.objectValue))
        XCTAssertEqual(usage.usedTokens, 140)
        XCTAssertNil(usage.maxTokens)
        XCTAssertNil(usage.remainingPercent)
        XCTAssertNil(usage.lastUsage?.cacheWriteInputTokens)
        let cumulativeOnly = AppServerClient.parseContextUsage(["tokenUsage": .object([
            "total": .object(["totalTokens": .number(10000)]), "modelContextWindow": .number(400),
        ])])
        XCTAssertNil(cumulativeOnly.usedTokens)
        XCTAssertNil(cumulativeOnly.remainingPercent)
        XCTAssertNil(JSONValue.number(1e100).intValue)
    }

    @MainActor
    func testLegacyFlatUsageRemainsSupported() {
        let usage = AppServerClient.parseContextUsage(["tokenUsage": .object([
            "inputTokens": .number(100), "maxInputTokens": .number(400), "remainingInputTokens": .number(300),
        ])])
        XCTAssertEqual(usage.usedTokens, 100)
        XCTAssertEqual(usage.remainingPercent, 75)
        XCTAssertNil(usage.lastUsage)
        XCTAssertNil(usage.totalUsage)
    }

    @MainActor
    func testModelCataloguePreservesModernAndLegacyMetadata() throws {
        let raw = try Self.wire("""
        {"data":[{"id":"server-model","model":"server-model","displayName":"Server Model","description":"Description from server",
          "isDefault":true,"supportedReasoningEfforts":[{"reasoningEffort":"high","description":"More reasoning"}],"defaultReasoningEffort":"high",
          "inputModalities":["text","image"],"multiAgentVersion":"v2","serviceTiers":[{"id":"priority","name":"Priority","description":"Server tier"}],
          "defaultServiceTier":"priority","upgradeInfo":{"model":"next-model","upgradeCopy":"Try next"}},
          {"id":"legacy-model","reasoningEffort":["low"],"defaultReasoningEffort":"low"}],"nextCursor":null}
        """)
        let payload = try AppServerClient().decode(raw, as: ModelListResponsePayload.self)
        let models = AppServerClient.parseModelCatalog(payload.data)
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].description, "Description from server")
        XCTAssertEqual(models[0].inputModalities, ["text", "image"])
        XCTAssertEqual(models[0].multiAgentVersion, "v2")
        XCTAssertEqual(models[0].serviceTiers.first?.id, "priority")
        XCTAssertEqual(models[0].defaultServiceTier, "priority")
        XCTAssertEqual(models[0].upgradeInfo?.model, "next-model")
        XCTAssertEqual(models[0].defaultReasoningEffort, "high")
        XCTAssertTrue(models[0].isDefault)
        XCTAssertNil(models[1].description)
        XCTAssertTrue(models[1].inputModalities.isEmpty)
        XCTAssertTrue(models[1].serviceTiers.isEmpty)
        XCTAssertEqual(models[1].reasoningEffortOptions.map(\.value), ["low"])
    }

    @MainActor
    func testActiveMetadataWithoutTurnIdentityBlocksCompetingStart() async throws {
        let client = AppServerClient()
        client.requestOverrideForTesting = { method, _ in
            if method == "thread/read" { return .object(["thread": Self.thread("t", status: "active")]) }
            return Self.page([])
        }
        _ = try await client.threadRead(threadID: "t")
        XCTAssertNil(client.activeTurnID(for: "t"))
        client.requestOverrideForTesting = { _, _ in XCTFail("An active thread must not start a competing turn"); return .null }
        do { _ = try await client.turnStart(threadID: "t", inputText: "Run", model: nil, effort: nil); XCTFail("Expected busy guard") }
        catch { guard case CodexOfficialError.threadBusy = error else { return XCTFail("Unexpected error: \(error)") } }
    }

    @MainActor
    func testNewerNameClearAndWaitingStatusWinOverHistorySnapshot() async throws {
        let client = AppServerClient()
        client.threadNamesByID["t"] = "Before"
        client.requestOverrideForTesting = { [weak client] method, _ in
            if method == "thread/read" {
                var thread = Self.thread("t").objectValue!
                thread["name"] = .string("Stale title")
                return .object(["thread": .object(thread)])
            }
            client?.applyNotificationForTesting(method: "thread/name/updated", params: .object([
                "threadId": .string("t"), "threadName": .null,
            ]))
            client?.applyNotificationForTesting(method: "thread/status/changed", params: .object([
                "threadId": .string("t"), "status": .object([
                    "type": .string("active"), "activeFlags": .array([.string("waitingOnUserInput")]),
                ]),
            ]))
            return Self.page([Self.turn("live", status: "inProgress")])
        }
        _ = try await client.threadRead(threadID: "t")
        XCTAssertNil(client.threadNamesByID["t"])
        XCTAssertNil(client.threadRecordsByID["t"]?.name)
        XCTAssertEqual(client.threadRecordsByID["t"]?.status?.activeFlags, ["waitingOnUserInput"])
    }

    @MainActor
    func testExplicitHistoryCursorCannotSilentlyFallBackToAnotherRange() async {
        let client = AppServerClient()
        var fullReads = 0
        client.requestOverrideForTesting = { method, params in
            if method == "thread/turns/list" { throw AppServerClientError.remote(code: -32601, message: "Method not found") }
            if params?["includeTurns"] == .bool(true) { fullReads += 1 }
            return .object(["thread": Self.thread("t")])
        }
        do {
            _ = try await client.threadRead(threadID: "t", turnsCursor: "opaque-range", turnsSortDirection: "desc")
            XCTFail("The selected cursor must not be silently discarded")
        } catch { XCTAssertEqual(fullReads, 0) }
    }

    @MainActor
    func testIdenticalReusedRequestIDCannotApproveOldArrival() async throws {
        for reconnect in [false, true] {
            let client = AppServerClient()
            let params: JSONValue = .object(["threadId": .string("t"), "turnId": .string("turn"), "itemId": .string("file")])
            client.applyServerRequestForTesting(id: .number(1), method: "item/fileChange/requestApproval", params: params)
            let old = try XCTUnwrap(client.pendingRequests.first)
            if reconnect { client.disconnect() }
            client.applyServerRequestForTesting(id: .number(1), method: "item/fileChange/requestApproval", params: params)
            let replacement = try XCTUnwrap(client.pendingRequests.first)
            XCTAssertEqual(old.rpcID, replacement.rpcID)
            XCTAssertEqual(old.kind, replacement.kind)
            XCTAssertNotEqual(old.instanceID, replacement.instanceID)
            XCTAssertNotEqual(old.id, replacement.id)
            var sends = 0
            client.responseOverrideForTesting = { _, _ in sends += 1 }
            do { try await client.respondFileChangeApproval(request: old, decision: .accept); XCTFail("Stale arrival must fail") }
            catch { guard case AppServerOfficialRequestError.requestResolved = error else { return XCTFail("Unexpected error: \(error)") } }
            XCTAssertEqual(sends, 0)
            XCTAssertEqual(client.pendingRequests.first?.instanceID, replacement.instanceID)
        }
    }

    @MainActor
    func testSuccessfulResponseOnlyRemovesItsOwnArrival() async throws {
        let client = AppServerClient()
        let params: JSONValue = .object(["threadId": .string("t"), "turnId": .string("turn"), "itemId": .string("file")])
        client.applyServerRequestForTesting(id: .number(1), method: "item/fileChange/requestApproval", params: params)
        let original = try XCTUnwrap(client.pendingRequests.first)
        client.responseOverrideForTesting = { [weak client] request, result in
            XCTAssertEqual(request.instanceID, original.instanceID)
            XCTAssertEqual(result["decision"], .string("accept"))
            client?.applyServerRequestForTesting(id: .number(1), method: "item/fileChange/requestApproval", params: params)
        }
        try await client.respondFileChangeApproval(request: original, decision: .accept)
        XCTAssertEqual(client.pendingRequests.count, 1)
        XCTAssertNotEqual(client.pendingRequests.first?.instanceID, original.instanceID)
    }

    @MainActor
    func testFailedResponseRetainsPendingArrivalAndDuplicateSubmissionIsBlocked() async throws {
        let client = AppServerClient()
        client.applyServerRequestForTesting(id: .number(1), method: "item/fileChange/requestApproval", params: .object([
            "threadId": .string("t"), "turnId": .string("turn"), "itemId": .string("file"),
        ]))
        let request = try XCTUnwrap(client.pendingRequests.first)
        var sends = 0
        client.responseOverrideForTesting = { [weak client] pending, _ in
            sends += 1
            do { try await client?.respondFileChangeApproval(request: pending, decision: .accept); XCTFail("Concurrent response must fail") }
            catch { guard case AppServerOfficialRequestError.requestResolved = error else { return XCTFail("Unexpected error: \(error)") } }
            throw AppServerClientError.notConnected
        }
        do { try await client.respondFileChangeApproval(request: request, decision: .accept); XCTFail("Send must fail") }
        catch { XCTAssertEqual(client.pendingRequests.first?.instanceID, request.instanceID) }
        XCTAssertEqual(sends, 1)
        client.responseOverrideForTesting = { _, _ in }
        try await client.respondFileChangeApproval(request: request, decision: .decline)
        XCTAssertTrue(client.pendingRequests.isEmpty)
    }

    func testRouterRetirementCannotFailRequestsFromNewConnection() async throws {
        let router = AppServerMessageRouter()
        let stored = XCTestExpectation(description: "Both connection generations stored")
        stored.expectedFulfillmentCount = 2
        let old = Task<JSONValue, Error> {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    await router.storeContinuation(continuation, for: "1", generation: 1)
                    stored.fulfill()
                }
            }
        }
        let current = Task<JSONValue, Error> {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    await router.storeContinuation(continuation, for: "2", generation: 2)
                    stored.fulfill()
                }
            }
        }
        await fulfillment(of: [stored], timeout: 1)
        await router.failAll(with: AppServerClientError.notConnected, generation: 1)
        do { _ = try await old.value; XCTFail("Retired connection request must fail") }
        catch { guard case AppServerClientError.notConnected = error else { return XCTFail("Unexpected error: \(error)") } }
        await router.resolveResponse(id: .number(2), result: .string("current response"), error: nil)
        let value = try await current.value
        XCTAssertEqual(value, .string("current response"))
    }

    private static func wire(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private static func page(_ data: [JSONValue], cursor: String? = nil) -> JSONValue {
        .object(["data": .array(data), "nextCursor": cursor.map(JSONValue.string) ?? .null])
    }

    private static func thread(_ id: String, updatedAt: Double = 100, status: String = "idle",
                               historyMode: String? = "paginated", turns: [JSONValue] = [],
                               canAcceptDirectInput: Bool = true) -> JSONValue {
        var value: [String: JSONValue] = [
            "id": .string(id), "preview": .string("Saved conversation"), "updatedAt": .number(updatedAt),
            "cwd": .string("/workspace/project"), "ephemeral": .bool(false), "source": .string("cli"),
            "status": status == "active"
                ? .object(["type": .string(status), "activeFlags": .array([])])
                : .object(["type": .string(status)]),
            "canAcceptDirectInput": .bool(canAcceptDirectInput), "turns": .array(turns),
        ]
        if let historyMode { value["historyMode"] = .string(historyMode) }
        return .object(value)
    }

    private static func turn(_ id: String, status: String = "completed", text: String = "A response") -> JSONValue {
        .object(["id": .string(id), "status": .string(status), "itemsView": .string("full"),
                 "items": .array([.object(["id": .string("item-\(id)"), "type": .string("agentMessage"), "text": .string(text)])])])
    }

    private static func turnEvent(_ id: String, status: String) -> JSONValue {
        .object(["threadId": .string("t"), "turn": .object(["id": .string(id), "status": .string(status), "items": .array([])])])
    }
}
