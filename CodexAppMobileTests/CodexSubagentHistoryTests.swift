import XCTest
@testable import CodexAppMobile

final class CodexSubagentHistoryTests: XCTestCase {
    func testRawToolAndFutureFieldsSurviveDecoding() throws {
        let value = Self.item("future-1", type: "futureTool", fields: [
            "text": .object(["nested": .string("new shape")]), "content": .array([.string("new content")]),
            "arguments": .object(["path": .string("/workspace/a.swift")]),
            "result": .object(["nested": .array([.bool(true), .number(3)])]),
        ])
        let decoded = try Self.decode(value, as: ThreadReadItemPayload.self)
        XCTAssertEqual(decoded.rawValue, value)
        XCTAssertEqual(decoded.type, "futureTool")
        XCTAssertNil(decoded.content)
        XCTAssertNil(decoded.text)
    }

    func testReasoningStringContentDoesNotBreakUserMessageDecoder() throws {
        let decoded = try Self.decode(Self.item("r", type: "reasoning", fields: [
            "summary": .array([.string("Reported summary")]),
            "content": .array([.string("Additional content")]),
        ]), as: ThreadReadItemPayload.self)
        XCTAssertNil(decoded.content)
        XCTAssertEqual(decoded.summary, [.string("Reported summary")])
        XCTAssertEqual(decoded.rawValue["content"], .array([.string("Additional content")]))
    }

    @MainActor
    func testConversionRetainsRichPayloadAndExistingTranscriptBehavior() throws {
        let rawItems = [Self.command(status: "completed", output: "Passed"), Self.fileChange()]
        let payload = try Self.decode(Self.thread("child", turns: [Self.turn(items: rawItems)]), as: ThreadReadThreadPayload.self)
        let detail = AppServerClient().convertThread(payload)
        XCTAssertEqual(detail.turns.first?.rawItems, rawItems)
        XCTAssertEqual(detail.turns.first?.items, [
            .commandExecution(id: "cmd", command: "swift test", status: "completed", output: "Passed"),
            .fileChange(id: "patch", status: "completed", changedFiles: 2),
        ])
        let transcript = AppServerClient.renderThread(detail)
        XCTAssertTrue(transcript.contains("$ swift test [completed]\nPassed"))
        XCTAssertTrue(transcript.contains("File change [completed] files=2"))
    }

    func testMessagesAndSummariesHaveSeparateRolesAndMarkdownBodies() {
        let markdown = "## Result\n\n```swift\nlet value = 1\n```"
        let cards = Self.cards([
            Self.item("u", type: "userMessage", fields: ["content": .array([
                .object(["type": .string("text"), "text": .string("Please inspect **this**")]),
                .object(["type": .string("localImage"), "path": .string("/workspace/image.png")]),
            ])]),
            Self.item("a", type: "agentMessage", fields: ["text": .string(markdown)]),
            Self.item("p", type: "plan", fields: ["text": .string("- Run tests")]),
            Self.item("r", type: "reasoning", fields: ["summary": .array([.string("Reported summary")])]),
        ])
        XCTAssertEqual(cards.map(\.kind), [.user, .assistant, .plan, .reasoning])
        XCTAssertEqual(cards[0].body?.text, "Please inspect **this**\n\nImage: /workspace/image.png")
        XCTAssertEqual(cards[1].body?.text, markdown)
        XCTAssertEqual(cards[3].title, "Reasoning summary")
    }

    func testCommandCardIncludesDirectoryExitCodeDurationOutputAndActions() throws {
        let card = try XCTUnwrap(Self.cards([Self.command(status: "failed", output: "Compiler error")]).first)
        XCTAssertEqual(card.kind, .command)
        XCTAssertEqual(card.status, "failed")
        XCTAssertEqual(card.body?.text, "swift test")
        XCTAssertEqual(card.fields.first { $0.label == "Directory" }?.value, "/workspace/repo")
        XCTAssertEqual(card.fields.first { $0.label == "Exit code" }?.value, "1")
        XCTAssertEqual(card.fields.first { $0.label == "Duration" }?.value, "150 ms")
        XCTAssertEqual(card.sections.first { $0.title == "Output" }?.content.text, "Compiler error")
        XCTAssertTrue(card.sections.contains { $0.title == "Actions" })
    }

    func testFileChangeCardPreservesEachPathOperationMoveAndDiff() throws {
        let card = try XCTUnwrap(Self.cards([Self.fileChange()]).first)
        XCTAssertEqual(card.kind, .fileChange)
        XCTAssertEqual(card.files.map(\.path), ["Sources/Old.swift", "Sources/New.swift"])
        XCTAssertEqual(card.files.map(\.kind), ["update", "add"])
        XCTAssertEqual(card.files[0].destination, "Sources/Renamed.swift")
        XCTAssertEqual(card.files[0].diff.text, "- old\n+ updated")
        XCTAssertEqual(card.files[1].diff.text, "+ new")
    }

    func testToolCardsRetainArgumentsResultsErrorsAndDynamicOutput() {
        let cards = Self.cards([
            Self.item("m", type: "mcpToolCall", fields: [
                "server": .string("docs"), "tool": .string("lookup"), "status": .string("failed"),
                "arguments": .object(["query": .string("Swift")]),
                "result": .object(["content": .array([.object(["type": .string("text"), "text": .string("Partial answer")])])]),
                "error": .object(["message": .string("Timed out")]),
            ]),
            Self.item("d", type: "dynamicToolCall", fields: [
                "namespace": .string("editor"), "tool": .string("inspect"), "status": .string("completed"),
                "arguments": .array([]), "success": .bool(true),
                "contentItems": .array([.object(["type": .string("inputText"), "text": .string("Found symbol")])]),
            ]),
        ])
        XCTAssertEqual(cards.map(\.kind), [.tool, .tool])
        XCTAssertEqual(cards[0].title, "lookup")
        XCTAssertEqual(cards[0].sections.map(\.title), ["Arguments", "Result", "Error"])
        XCTAssertTrue(cards[0].sections[2].content.text.contains("Timed out"))
        XCTAssertEqual(cards[1].fields.first { $0.label == "Succeeded" }?.value, "Yes")
        XCTAssertTrue(cards[1].sections.contains { $0.title == "Output" && $0.content.text.contains("Found symbol") })
    }

    func testAgentNavigationUsesOnlyReportedDestinations() {
        let cards = Self.cards([
            Self.item("c", type: "collabAgentToolCall", fields: [
                "tool": .string("spawnAgent"), "prompt": .string("Mentioned thread untrusted-id"),
                "receiverThreadIds": .array([.string("child-2"), .string("child-2"), .string(""), .string("child-3")]),
            ]),
            Self.item("s", type: "subAgentActivity", fields: ["agentThreadId": .string("reported-child")]),
            Self.item("p", type: "collabAgentToolCall", fields: ["prompt": .string("Open thread fabricated-id")]),
        ])
        XCTAssertEqual(cards[0].destinations, ["child-2", "child-3"])
        XCTAssertEqual(cards[1].destinations, ["reported-child"])
        XCTAssertTrue(cards[2].destinations.isEmpty)
    }

    func testUnknownItemIsRetainedWithNamedStructuredDetails() throws {
        let card = try XCTUnwrap(Self.cards([Self.item("future", type: "futureCapability", fields: [
            "newField": .object(["answer": .number(42)]),
        ])]).first)
        XCTAssertEqual(card.title, "futureCapability")
        XCTAssertEqual(card.kind, .event)
        XCTAssertEqual(card.sections.first?.title, "Details")
        XCTAssertTrue(card.sections.first?.content.text.contains("newField") == true)
    }

    func testCardIdentityIsStableAcrossUpdatesAndDistinctAcrossTurnsAndDuplicates() {
        let before = Self.cards([Self.command(status: "inProgress", output: "A")])
        let after = Self.cards([Self.command(status: "completed", output: "A\nB")])
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        let otherTurn = Self.cards([Self.command(status: "completed", output: "A\nB")], turnID: "other")
        XCTAssertNotEqual(before[0].id, otherTurn[0].id)
        let duplicates = Self.cards([Self.command(status: "completed", output: "A"), Self.command(status: "completed", output: "B")])
        XCTAssertNotEqual(duplicates[0].id, duplicates[1].id)
    }

    func testOutputPreviewIsBoundedWithoutSplittingGraphemes() throws {
        let source = String(repeating: "👩🏽‍💻", count: CodexHistoryPreview.maximumCharacters + 7)
        let card = try XCTUnwrap(Self.cards([Self.command(status: "completed", output: source)]).first)
        let preview = try XCTUnwrap(card.sections.first { $0.title == "Output" }?.content)
        XCTAssertEqual(preview.text.count, CodexHistoryPreview.maximumCharacters)
        XCTAssertTrue(preview.isTruncated)
        XCTAssertEqual(preview.text.last, "👩🏽‍💻")
        XCTAssertFalse(CodexHistoryPreview("Short output").isTruncated)
    }

    @MainActor
    func testHistoryReadUsesFullPaginationAndUpdatesExistingCardsWithoutMutations() async throws {
        let client = AppServerClient()
        client.setStateForTesting(.connected)
        let history = CodexSubagentHistoryModel()
        var completed = false
        var methods: [String] = []
        client.requestOverrideForTesting = { method, params in
            methods.append(method)
            XCTAssertEqual(params?["threadId"], .string("child"))
            if method == "thread/read" { return .object(["thread": Self.thread("child")]) }
            XCTAssertEqual(method, "thread/turns/list")
            XCTAssertEqual(params?["itemsView"], .string("full"))
            if params?["cursor"] == nil {
                return Self.page([Self.turn(id: "older", items: [Self.item("answer", type: "agentMessage", fields: ["text": .string("Earlier")])])], next: "page2")
            }
            return Self.page([Self.turn(status: completed ? "completed" : "inProgress", items: [
                Self.command(status: completed ? "completed" : "inProgress", output: completed ? "Done" : "Starting"),
            ])])
        }
        await history.refresh(client: client, threadID: "child")
        let itemID = try XCTUnwrap(history.turns.last?.items.first?.id)
        XCTAssertEqual(history.turns.map(\.id), ["older", "turn"])
        XCTAssertTrue(history.hasActiveTurn)
        completed = true
        await history.refresh(client: client, threadID: "child")
        XCTAssertEqual(history.turns.last?.items.count, 1)
        XCTAssertEqual(history.turns.last?.items.first?.id, itemID)
        XCTAssertEqual(history.turns.last?.items.first?.status, "completed")
        XCTAssertFalse(history.hasActiveTurn)
        XCTAssertEqual(Set(methods), Set(["thread/read", "thread/turns/list"]))
    }

    @MainActor
    func testConcurrentRefreshDoesNotStartOverlappingRead() async throws {
        let client = AppServerClient()
        client.setStateForTesting(.connected)
        let history = CodexSubagentHistoryModel()
        var continuation: CheckedContinuation<JSONValue, Never>?
        var reads = 0
        client.requestOverrideForTesting = { method, _ in
            if method == "thread/read" {
                reads += 1
                return await withCheckedContinuation { continuation = $0 }
            }
            return Self.page([Self.turn(items: [])])
        }
        let first = Task { await history.refresh(client: client, threadID: "child") }
        let started = await waitUntil { continuation != nil }
        XCTAssertTrue(started)
        await history.refresh(client: client, threadID: "child")
        XCTAssertEqual(reads, 1)
        continuation?.resume(returning: .object(["thread": Self.thread("child")]))
        await first.value
        XCTAssertTrue(history.hasLoaded)
        XCTAssertFalse(history.isLoading)
    }

    @MainActor
    func testChangingChildDiscardsPriorResponseAndKeepsNewSnapshot() async {
        let client = AppServerClient()
        client.setStateForTesting(.connected)
        let history = CodexSubagentHistoryModel()
        var priorRead: CheckedContinuation<JSONValue, Never>?
        client.requestOverrideForTesting = { method, params in
            let id = params?["threadId"]?.stringValue ?? ""
            if method == "thread/read" {
                if id == "old-child" { return await withCheckedContinuation { priorRead = $0 } }
                return .object(["thread": Self.thread(id)])
            }
            return Self.page([Self.turn(items: [Self.item("reply", type: "agentMessage", fields: ["text": .string(id)])])])
        }
        let oldTask = Task { await history.refresh(client: client, threadID: "old-child") }
        let started = await waitUntil { priorRead != nil }
        XCTAssertTrue(started)
        await history.refresh(client: client, threadID: "new-child")
        priorRead?.resume(returning: .object(["thread": Self.thread("old-child")]))
        await oldTask.value
        XCTAssertEqual(history.scope?.threadID, "new-child")
        XCTAssertEqual(history.turns.first?.items.first?.body?.text, "new-child")
        XCTAssertFalse(history.isLoading)
    }

    @MainActor
    func testConnectionChangeClearsPreviousSnapshotAndRejectsLateResponse() async {
        let client = AppServerClient()
        client.setStateForTesting(.connected)
        let history = CodexSubagentHistoryModel()
        Self.installHistory(on: client, text: "Previous connection")
        await history.refresh(client: client, threadID: "child")
        XCTAssertTrue(history.hasLoaded)
        client.requestOverrideForTesting = { [weak client] _, _ in
            client?.disconnect()
            return .object(["thread": Self.thread("child")])
        }
        await history.refresh(client: client, threadID: "child")
        XCTAssertTrue(history.turns.isEmpty)
        XCTAssertFalse(history.hasLoaded)
        XCTAssertEqual(history.scope?.generation, client.connectionGeneration)
        XCTAssertNil(history.errorMessage)
    }

    @MainActor
    func testFailedRefreshPreservesSnapshotAndLaterReadRecovers() async {
        let client = AppServerClient()
        client.setStateForTesting(.connected)
        let history = CodexSubagentHistoryModel()
        Self.installHistory(on: client, text: "Existing response")
        await history.refresh(client: client, threadID: "child")
        let existing = history.turns
        client.requestOverrideForTesting = { _, _ in throw AppServerClientError.remote(code: -32000, message: "Temporarily unavailable") }
        await history.refresh(client: client, threadID: "child")
        XCTAssertEqual(history.turns, existing)
        XCTAssertNotNil(history.errorMessage)
        XCTAssertFalse(history.isLoading)
        Self.installHistory(on: client, text: "Updated response")
        await history.refresh(client: client, threadID: "child")
        XCTAssertNil(history.errorMessage)
        XCTAssertEqual(history.turns.first?.items.first?.body?.text, "Updated response")
    }

    @MainActor
    func testCancelledRefreshCannotPublishLateSnapshot() async {
        let client = AppServerClient()
        client.setStateForTesting(.connected)
        let history = CodexSubagentHistoryModel()
        var continuation: CheckedContinuation<JSONValue, Never>?
        client.requestOverrideForTesting = { method, _ in
            if method == "thread/read" { return await withCheckedContinuation { continuation = $0 } }
            return Self.page([])
        }
        let task = Task { await history.refresh(client: client, threadID: "child") }
        let started = await waitUntil { continuation != nil }
        XCTAssertTrue(started)
        task.cancel()
        history.cancelRefresh()
        continuation?.resume(returning: .object(["thread": Self.thread("child")]))
        await task.value
        XCTAssertTrue(history.turns.isEmpty)
        XCTAssertFalse(history.hasLoaded)
        XCTAssertFalse(history.isLoading)
        XCTAssertNil(history.errorMessage)
    }

    private static func cards(_ items: [JSONValue], turnID: String = "turn") -> [CodexAgentHistoryItem] {
        CodexAgentHistoryItem.items(in: .init(id: turnID, status: "completed", items: [], model: nil,
                                            reasoningEffort: nil, rawItems: items))
    }

    private static func item(_ id: String, type: String, fields: [String: JSONValue] = [:]) -> JSONValue {
        .object(fields.merging(["id": .string(id), "type": .string(type)]) { _, new in new })
    }

    private static func command(status: String, output: String) -> JSONValue {
        item("cmd", type: "commandExecution", fields: [
            "command": .string("swift test"), "cwd": .string("/workspace/repo"), "status": .string(status),
            "exitCode": .number(1), "durationMs": .number(150), "aggregatedOutput": .string(output),
            "commandActions": .array([.object(["type": .string("unknown"), "command": .string("swift test")])]),
        ])
    }

    private static func fileChange() -> JSONValue {
        item("patch", type: "fileChange", fields: ["status": .string("completed"), "changes": .array([
            .object(["path": .string("Sources/Old.swift"), "kind": .object(["type": .string("update"), "movePath": .string("Sources/Renamed.swift")]),
                     "diff": .string("- old\n+ updated")]),
            .object(["path": .string("Sources/New.swift"), "kind": .object(["type": .string("add")]), "diff": .string("+ new")]),
        ])])
    }

    private static func turn(id: String = "turn", status: String = "completed", items: [JSONValue]) -> JSONValue {
        .object(["id": .string(id), "status": .string(status), "itemsView": .string("full"), "items": .array(items)])
    }

    private static func thread(_ id: String, turns: [JSONValue] = []) -> JSONValue {
        .object(["id": .string(id), "preview": .string("Child"), "cwd": .string("/workspace/repo"),
                 "createdAt": .number(1), "updatedAt": .number(2), "ephemeral": .bool(false),
                 "historyMode": .string("paginated"), "status": .object(["type": .string("idle")]), "turns": .array(turns)])
    }

    private static func page(_ turns: [JSONValue], next: String? = nil) -> JSONValue {
        .object(["data": .array(turns), "nextCursor": next.map(JSONValue.string) ?? .null])
    }

    private static func decode<T: Decodable>(_ value: JSONValue, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    @MainActor
    private static func installHistory(on client: AppServerClient, text: String) {
        client.requestOverrideForTesting = { method, params in
            if method == "thread/read" { return .object(["thread": Self.thread(params?["threadId"]?.stringValue ?? "")]) }
            return Self.page([Self.turn(items: [Self.item("reply", type: "agentMessage", fields: ["text": .string(text)])])])
        }
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
