import XCTest
@testable import CodexAppMobile

final class CodexComposerDraftTests: XCTestCase {
    func testDraftsSeparateHostsWorkspacesThreadsAndNewThreadScope() {
        let host = UUID(), workspace = UUID()
        let scopes = [
            CodexComposerDraftScope(hostID: host, workspaceID: workspace, threadID: "same"),
            CodexComposerDraftScope(hostID: UUID(), workspaceID: workspace, threadID: "same"),
            CodexComposerDraftScope(hostID: host, workspaceID: UUID(), threadID: "same"),
            CodexComposerDraftScope(hostID: host, workspaceID: workspace, threadID: nil),
        ]
        var store = CodexComposerDraftStore()
        for (index, scope) in scopes.enumerated() {
            store.save(Self.draft("Draft \(index)", token: "skill-\(index)"), for: scope)
        }
        for (index, scope) in scopes.enumerated() {
            XCTAssertEqual(store.draft(for: scope), Self.draft("Draft \(index)", token: "skill-\(index)"))
        }
        store.save(CodexComposerDraft(), for: scopes[0])
        XCTAssertTrue(store.draft(for: scopes[0]).isEmpty)
        XCTAssertEqual(store.draft(for: scopes[1]).text, "Draft 1")
    }

    func testScopeTransitionSavesLoadedScopeBeforeAdoptingCombinedSelection() {
        let a = Self.submission(threadID: "a").scope
        let b = Self.submission(threadID: "b").scope
        var store = CodexComposerDraftStore()
        let draftA = Self.draft("Unsent A", token: "a")
        let draftB = Self.draft("Unsent B", token: "b")
        store.save(draftB, for: b)
        let restoredB = store.switchScope(from: a, to: b, currentDraft: draftA)
        XCTAssertEqual(restoredB, draftB)
        XCTAssertEqual(store.draft(for: a), draftA)
        XCTAssertEqual(store.switchScope(from: b, to: a, currentDraft: restoredB), draftA)
    }

    func testNewThreadDraftSurvivesNavigationWithoutCreatingSubmission() {
        let scope = Self.submission(threadID: nil).scope
        let draft = Self.draft("Keep after leaving", token: "review")
        var store = CodexComposerDraftStore()
        XCTAssertTrue(store.switchScope(from: scope, to: nil, currentDraft: draft).isEmpty)
        XCTAssertEqual(store.switchScope(from: nil, to: scope, currentDraft: CodexComposerDraft()), draft)
        XCTAssertFalse(store.hasPendingSubmission(in: scope))
    }

    func testPendingSubmissionBlocksDuplicateNewThreadDispatchOnlyInItsScope() {
        let first = Self.submission(threadID: nil)
        let duplicate = Self.submission(host: first.host, workspace: first.workspace, threadID: nil)
        let another = Self.submission(host: first.host, workspace: first.workspace, threadID: "existing")
        var store = CodexComposerDraftStore()
        XCTAssertTrue(store.begin(first))
        store.save(Self.draft("Typed while connecting"), for: first.scope)
        XCTAssertFalse(store.begin(duplicate))
        XCTAssertEqual(store.draft(for: first.scope).text, "Typed while connecting")
        XCTAssertTrue(store.begin(another))
        store.complete(first.id)
        XCTAssertFalse(store.hasPendingSubmission(in: first.scope))
        XCTAssertTrue(store.hasPendingSubmission(in: another.scope))
        XCTAssertEqual(store.draft(for: first.scope).text, "Typed while connecting")
    }

    func testFailurePreservesNewerDraftAndUnrelatedComposerUntilExplicitRecovery() throws {
        let submission = Self.submission(threadID: "a", draft: Self.draft("Original\ninput", token: "old"))
        let otherScope = CodexComposerDraftScope(
            hostID: submission.host.id, workspaceID: submission.workspace.id, threadID: "b"
        )
        let newer = Self.draft("Newer draft", token: "new")
        let unrelated = Self.draft("Do not touch B", token: "other")
        var store = CodexComposerDraftStore()
        XCTAssertTrue(store.begin(submission))
        store.save(newer, for: submission.scope)
        store.save(unrelated, for: otherScope)
        store.fail(submission.id)
        store.fail(submission.id)
        XCTAssertEqual(store.draft(for: submission.scope), newer)
        XCTAssertEqual(store.draft(for: otherScope), unrelated)
        XCTAssertEqual(store.failedDrafts(in: submission.scope).count, 1)
        XCTAssertTrue(store.failedDrafts(in: otherScope).isEmpty)
        XCTAssertFalse(store.hasPendingSubmission(in: submission.scope))

        XCTAssertNil(store.restoreFailure(submission.id, in: otherScope))
        let restored = try XCTUnwrap(store.restoreFailure(submission.id, in: submission.scope))
        XCTAssertEqual(restored.text, "Original\ninput\n\nNewer draft")
        XCTAssertEqual(restored.contextTokens.map(\.token), ["$old", "$new"])
        XCTAssertEqual(store.draft(for: otherScope), unrelated)
        XCTAssertTrue(store.failedDrafts(in: submission.scope).isEmpty)
        XCTAssertFalse(store.hasPendingSubmission(in: submission.scope), "Restoration must never submit or replay input.")
    }

    func testFailureWithEmptyDraftRestoresExactTextAndTokens() throws {
        let submission = Self.submission(threadID: "a", draft: Self.draft(" \nLiteral text, unchanged\n ", token: "context"))
        var store = CodexComposerDraftStore()
        XCTAssertTrue(store.begin(submission))
        store.fail(submission.id)
        XCTAssertTrue(store.draft(for: submission.scope).isEmpty)
        XCTAssertEqual(try XCTUnwrap(store.restoreFailure(submission.id, in: submission.scope)), submission.draft)
    }

    func testCreatedThreadCannotReplaceNewerSelectionOrHiddenWorkbench() {
        let submission = Self.submission(threadID: nil)
        let other = CodexComposerDraftScope(
            hostID: submission.host.id, workspaceID: submission.workspace.id, threadID: "b"
        )
        XCTAssertTrue(submission.maySelectCreatedThread(currentScope: submission.scope, isVisible: true))
        XCTAssertFalse(submission.maySelectCreatedThread(currentScope: other, isVisible: true))
        XCTAssertFalse(submission.maySelectCreatedThread(currentScope: submission.scope, isVisible: false))
        let existing = Self.submission(threadID: "a")
        XCTAssertFalse(existing.maySelectCreatedThread(currentScope: existing.scope, isVisible: true))
    }

    @MainActor
    func testReconnectKeepsCapturedThreadAndSettingsAfterSelectionChanges() async throws {
        let submission = Self.submission(threadID: "a", draft: Self.draft("  Send original  ", token: "review"))
        let client = AppServerClient()
        var selectedThread = "a"
        var selectedModel = "captured-model"
        var methods: [String] = []
        client.requestOverrideForTesting = { method, params in
            methods.append(method)
            XCTAssertEqual(params?.objectValue?["threadId"], .string("a"))
            switch method {
            case "thread/resume", "thread/read":
                return .object(["thread": Self.thread("a")])
            case "thread/turns/list":
                return Self.page([])
            case "turn/start":
                XCTAssertEqual(params?.objectValue?["model"], .string("captured-model"))
                XCTAssertEqual(params?.objectValue?["effort"], .string("high"))
                XCTAssertEqual(params?.objectValue?["collaborationMode"]?.objectValue?["mode"], .string("plan"))
                XCTAssertEqual(params?.objectValue?["input"]?.arrayValue?.first?.objectValue?["text"],
                               .string("$review\nSend original"))
                return .object(["turn": Self.turn("started", status: "inProgress")])
            default:
                throw AppServerClientError.malformedResponse
            }
        }
        let result = try await submission.dispatch(using: client, connect: { host in
            XCTAssertEqual(host.id, submission.host.id)
            selectedThread = "b"
            selectedModel = "later-model"
            await Task.yield()
            client.setStateForTesting(.connected, host: host)
        })
        XCTAssertEqual(result.threadID, "a")
        XCTAssertEqual(selectedThread, "b")
        XCTAssertEqual(selectedModel, "later-model")
        XCTAssertEqual(methods, ["thread/resume", "thread/turns/list", "thread/read", "thread/turns/list", "turn/start"])
    }

    @MainActor
    func testReconnectSteersExactRecoveredActiveTurn() async throws {
        let submission = Self.submission(threadID: "a")
        let client = AppServerClient()
        var methods: [String] = []
        client.requestOverrideForTesting = { method, params in
            methods.append(method)
            switch method {
            case "thread/resume", "thread/read":
                return .object(["thread": Self.thread("a", status: "active")])
            case "thread/turns/list":
                return Self.page([Self.turn("running", status: "inProgress")])
            case "turn/steer":
                XCTAssertEqual(params?.objectValue?["threadId"], .string("a"))
                XCTAssertEqual(params?.objectValue?["expectedTurnId"], .string("running"))
                return .object(["turnId": .string("running")])
            default:
                XCTFail("An active turn must not create another thread or turn.")
                throw AppServerClientError.malformedResponse
            }
        }
        let result = try await submission.dispatch(using: client, connect: { host in
            client.setStateForTesting(.connected, host: host)
        })
        XCTAssertNil(result.startedTurn)
        XCTAssertEqual(methods.last, "turn/steer")
        XCTAssertTrue(methods.contains("thread/resume"))
        XCTAssertTrue(methods.contains("thread/read"))
    }

    @MainActor
    func testAttachedKnownActiveTurnAvoidsReloadingHistory() async throws {
        let submission = Self.submission(threadID: "a")
        let client = AppServerClient()
        client.setStateForTesting(.connected, host: submission.host)
        client.requestOverrideForTesting = { method, _ in
            switch method {
            case "thread/read": return .object(["thread": Self.thread("a", status: "active")])
            case "thread/turns/list": return Self.page([Self.turn("active", status: "inProgress")])
            default: throw AppServerClientError.malformedResponse
            }
        }
        _ = try await client.threadRead(threadID: "a")
        var methods: [String] = []
        client.requestOverrideForTesting = { method, params in
            methods.append(method)
            XCTAssertEqual(params?.objectValue?["expectedTurnId"], .string("active"))
            return .object([:])
        }
        _ = try await submission.dispatch(using: client)
        XCTAssertEqual(methods, ["turn/steer"])
    }

    @MainActor
    func testActiveThreadWithoutTurnIDRefusesDispatchAndKeepsRecovery() async {
        let submission = Self.submission(threadID: "a")
        let client = AppServerClient()
        client.setStateForTesting(.connected, host: submission.host)
        var methods: [String] = []
        client.requestOverrideForTesting = { method, _ in
            methods.append(method)
            if method == "thread/turns/list" { return Self.page([]) }
            return .object(["thread": Self.thread("a", status: "active")])
        }
        var store = CodexComposerDraftStore()
        XCTAssertTrue(store.begin(submission))
        do {
            _ = try await submission.dispatch(using: client)
            XCTFail("An unresolved active turn must fail safely.")
        } catch {
            XCTAssertTrue(error is CodexComposerSubmissionError)
            store.fail(submission.id)
        }
        XCTAssertFalse(methods.contains("turn/start"))
        XCTAssertFalse(methods.contains("turn/steer"))
        XCTAssertEqual(store.failedDrafts(in: submission.scope).first?.draft, submission.draft)
    }

    @MainActor
    func testHostChangeDuringReconciliationStopsBeforeNextRPC() async {
        let submission = Self.submission(threadID: "a")
        let anotherHost = Self.host()
        let client = AppServerClient()
        client.setStateForTesting(.connected, host: submission.host)
        var methods: [String] = []
        client.requestOverrideForTesting = { method, _ in
            methods.append(method)
            if method == "thread/turns/list" {
                client.setStateForTesting(.connected, host: anotherHost)
                return Self.page([])
            }
            return .object(["thread": Self.thread("a")])
        }
        do { _ = try await submission.dispatch(using: client); XCTFail("The captured host must still own the connection.") }
        catch {
            guard case CodexOfficialError.connectionChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(methods, ["thread/resume", "thread/turns/list"])
    }

    @MainActor
    func testReadOnlyThreadCannotStartOrSteerAfterReconciliation() async {
        let submission = Self.submission(threadID: "a")
        let client = AppServerClient()
        client.setStateForTesting(.connected, host: submission.host)
        var methods: [String] = []
        client.requestOverrideForTesting = { method, _ in
            methods.append(method)
            if method == "thread/turns/list" { return Self.page([]) }
            return .object(["thread": Self.thread("a", directInput: false)])
        }
        do { _ = try await submission.dispatch(using: client); XCTFail("Read-only metadata must block sending.") }
        catch {
            guard case AppServerClientError.readOnlyThread = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(methods.contains("turn/start"))
        XCTAssertFalse(methods.contains("turn/steer"))
    }

    private static func host() -> RemoteHost {
        RemoteHost(name: "Test", host: "host.invalid", sshPort: 22, username: "test",
                   appServerURL: "wss://host.invalid", preferredTransport: .appServerWS)
    }

    private static func draft(_ text: String, token: String? = nil) -> CodexComposerDraft {
        CodexComposerDraft(text: text, contextTokens: token.map {
            [CodexComposerContextToken(id: $0, token: "$" + $0, title: $0)]
        } ?? [])
    }

    private static func submission(host: RemoteHost? = nil, workspace: ProjectWorkspace? = nil,
                                   threadID: String?, draft: CodexComposerDraft? = nil) -> CodexComposerSubmission {
        let host = host ?? Self.host()
        let workspace = workspace ?? ProjectWorkspace(hostID: host.id, name: "Project", remotePath: "/project")
        return CodexComposerSubmission(
            scope: CodexComposerDraftScope(hostID: host.id, workspaceID: workspace.id, threadID: threadID),
            host: host, workspace: workspace, draft: draft ?? Self.draft("Original input"),
            model: "captured-model", reasoning: "high", collaborationModeID: "plan", forceNewThread: false
        )
    }

    private static func thread(_ id: String, status: String = "idle", directInput: Bool = true) -> JSONValue {
        .object([
            "id": .string(id), "cwd": .string("/project"), "preview": .string("Existing thread"),
            "updatedAt": .number(100), "ephemeral": .bool(false), "historyMode": .string("paginated"),
            "canAcceptDirectInput": .bool(directInput),
            "status": .object(["type": .string(status), "activeFlags": .array([])]), "turns": .array([]),
        ])
    }

    private static func turn(_ id: String, status: String) -> JSONValue {
        .object(["id": .string(id), "status": .string(status), "itemsView": .string("full"), "items": .array([])])
    }

    private static func page(_ turns: [JSONValue]) -> JSONValue {
        .object(["data": .array(turns), "nextCursor": .null])
    }
}
