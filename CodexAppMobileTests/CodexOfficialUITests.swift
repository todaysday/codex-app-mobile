import XCTest
import SwiftUI
import UIKit
@testable import CodexAppMobile

final class CodexOfficialUITests: XCTestCase {
    func testGoalBudgetEditorPreservesKeepRemoveAndNumericChoices() throws {
        XCTAssertEqual(CodexThreadControlPolicy.budgetChange(mode: .unchanged, text: "not a number"), .unchanged)
        XCTAssertEqual(CodexThreadControlPolicy.budgetChange(mode: .unlimited, text: "12000"), .unlimited)
        XCTAssertEqual(CodexThreadControlPolicy.budgetChange(mode: .limited, text: " 12000 "), .limit(12000))
        XCTAssertEqual(CodexThreadControlPolicy.budgetChange(mode: .limited, text: "0"), .limit(0))
        for text in ["", "-1", "1.5", "Infinity", "9007199254740992", String(repeating: "9", count: 40)] {
            XCTAssertNil(CodexThreadControlPolicy.budgetChange(mode: .limited, text: text), text)
        }
    }

    func testHistoryControlsRequireConfirmedIdleCompatibleThread() {
        let idle = Self.record()
        XCTAssertTrue(CodexThreadControlPolicy.canRevert(record: idle, activeTurnID: nil, isCompacting: false))
        for record in [Self.record(status: "active"), Self.record(status: "notLoaded"),
                       Self.record(status: "futureStatus"), Self.record(ephemeral: true),
                       Self.record(historyMode: "legacy"), Self.record(directInput: false)] {
            XCTAssertFalse(CodexThreadControlPolicy.canRevert(record: record, activeTurnID: nil, isCompacting: false))
        }
        XCTAssertFalse(CodexThreadControlPolicy.canRevert(record: nil, activeTurnID: nil, isCompacting: false))
        XCTAssertFalse(CodexThreadControlPolicy.canRevert(record: idle, activeTurnID: "running", isCompacting: false))
        XCTAssertFalse(CodexThreadControlPolicy.canRevert(record: idle, activeTurnID: nil, isCompacting: true))
        XCTAssertTrue(CodexThreadControlPolicy.acceptsDirectInput(nil), "Missing flags preserve older-server compatibility.")
        XCTAssertFalse(CodexThreadControlPolicy.acceptsDirectInput(false))
    }

    func testReadOnlyNavigationReturnsToExistingAncestorsAndBoundsCycles() {
        let path = ["child", "grandchild", "great-grandchild"]
        XCTAssertEqual(CodexSubagentNavigation.path(current: path, opening: "child", rootID: "root"), ["child"])
        XCTAssertEqual(CodexSubagentNavigation.path(current: path, opening: "great-grandchild", rootID: "root"), path)
        XCTAssertEqual(CodexSubagentNavigation.path(current: path, opening: "root", rootID: "root"), [])
        XCTAssertEqual(CodexSubagentNavigation.path(current: path, opening: "", rootID: "root"), path)
        XCTAssertEqual(CodexSubagentNavigation.path(current: path, opening: "reported-parent", rootID: "root"), path + ["reported-parent"])
    }

    func testStatusDisplayDistinguishesIdleNotLoadedAndWaitingStates() {
        XCTAssertEqual(CodexThreadControlPolicy.statusTitle(.init(type: "idle", activeFlags: nil)), "Idle")
        XCTAssertEqual(CodexThreadControlPolicy.statusTitle(.init(type: "notLoaded", activeFlags: nil)), "Not loaded")
        let waiting = CodexThreadControlPolicy.statusTitle(.init(type: "active", activeFlags: ["waitingOnApproval", "waitingOnUserInput"]))
        XCTAssertTrue(waiting.contains("Waiting for approval"))
        XCTAssertTrue(waiting.contains("Waiting for input"))
        XCTAssertEqual(CodexThreadControlPolicy.statusTitle(nil), "Status unavailable")
        XCTAssertEqual(CodexThreadControlPolicy.statusTitle(.init(type: "futureStatus", activeFlags: nil)), "futureStatus")
    }

    @MainActor
    func testOpeningNativeControlsOnlyReadsExistingThreadAndGoal() async throws {
        let client = AppServerClient()
        client.setStateForTesting(.connected)
        var methods: [String] = []
        client.requestOverrideForTesting = { method, _ in
            methods.append(method)
            switch method {
            case "thread/read": return .object(["thread": Self.thread("existing")])
            case "thread/turns/list": return .object(["data": .array([]), "nextCursor": .null])
            case "thread/goal/get": return .object(["goal": .null])
            default: throw AppServerClientError.remote(code: -32601, message: "Unexpected mutation")
            }
        }
        let (window, previous) = try mount(CodexThreadControlsView(client: client, threadID: "existing",
                                                                  modelID: nil, fallbackTitle: "Existing thread", onHistoryChanged: {}))
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let loaded = await waitUntil { methods.contains("thread/goal/get") }
        XCTAssertTrue(loaded)
        XCTAssertEqual(Set(methods), Set(["thread/read", "thread/turns/list", "thread/goal/get"]))
        XCTAssertNil(client.activeTurnID(for: "existing"))
        XCTAssertNil(client.threadGoalsByID["existing"])
    }

    @MainActor
    func testInspectingChildReadsMessagesWithoutTouchingActiveParent() async throws {
        let client = AppServerClient()
        client.setStateForTesting(.connected)
        client.applyNotificationForTesting(method: "turn/started", params: .object([
            "threadId": .string("parent"), "turn": .object(["id": .string("parent-turn"), "status": .string("inProgress")]),
        ]))
        var methods: [String] = []
        client.requestOverrideForTesting = { method, params in
            methods.append(method)
            XCTAssertEqual(params?.objectValue?["threadId"], .string("child"))
            switch method {
            case "thread/read": return .object(["thread": Self.thread("child", directInput: false)])
            case "thread/turns/list":
                return .object(["data": .array([.object([
                    "id": .string("child-turn"), "status": .string("completed"), "itemsView": .string("full"),
                    "items": .array([.object(["id": .string("reply"), "type": .string("agentMessage"), "text": .string("Existing child response")])]),
                ])]), "nextCursor": .null])
            default: throw AppServerClientError.remote(code: -32601, message: "Unexpected mutation")
            }
        }
        let view = NavigationStack {
            CodexSubagentThreadView(client: client, threadID: "child", rootThreadID: "parent", fallback: nil,
                                   openThread: { _ in }, returnToWorkbench: {})
        }
        let (window, previous) = try mount(view)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let loaded = await waitUntil { client.transcriptByThread["child"]?.contains("Existing child response") == true }
        XCTAssertTrue(loaded)
        XCTAssertEqual(Set(methods), Set(["thread/read", "thread/turns/list"]))
        XCTAssertEqual(client.activeTurnID(for: "parent"), "parent-turn")
        XCTAssertNil(client.activeTurnID(for: "child"))
        XCTAssertEqual(client.threadRecordsByID["child"]?.canAcceptDirectInput, false)
    }

    private static func record(status: String = "idle", ephemeral: Bool = false,
                               historyMode: String = "paginated", directInput: Bool = true) -> RemoteThreadRecord {
        RemoteThreadRecord(id: "thread", preview: "Preview", updatedAt: Date(), archived: false,
                           ephemeral: ephemeral, cwd: "/workspace/test", model: nil, reasoningEffort: nil,
                           status: .init(type: status, activeFlags: nil), canAcceptDirectInput: directInput, historyMode: historyMode)
    }

    private static func thread(_ id: String, directInput: Bool = true) -> JSONValue {
        .object(["id": .string(id), "preview": .string("Existing thread"), "cwd": .string("/workspace/test"),
                 "createdAt": .number(1), "updatedAt": .number(2), "ephemeral": .bool(false),
                 "historyMode": .string("paginated"), "canAcceptDirectInput": .bool(directInput),
                 "status": .object(["type": .string("idle"), "activeFlags": .array([])]), "turns": .array([])])
    }

    @MainActor
    private func mount<Content: View>(_ content: Content) throws -> (UIWindow, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        return (window, previous)
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}


final class CodexSubagentCardTests: XCTestCase {
    func testDistinctActionCardsRetainStatusAndOutput() {
        let command = CodexSubagentCardInfo(item: .commandExecution(
            id: "c", command: "swift test", status: "completed", output: "All tests passed"
        ))
        XCTAssertEqual(command.title, "Command")
        XCTAssertEqual(command.status, "completed")
        XCTAssertEqual(command.details, "All tests passed")

        let tool = CodexSubagentCardInfo(item: .toolCall(
            id: "mcp", tool: "github / search", status: "failed", details: "Error: unavailable"
        ))
        XCTAssertEqual(tool.title, "Tool · github / search")
        XCTAssertEqual(tool.status, "failed")
        XCTAssertEqual(tool.details, "Error: unavailable")

        let action = CodexSubagentCardInfo(item: .agentAction(
            id: "spawn", action: "spawnAgent", status: "inProgress", details: "Agents: child"
        ))
        XCTAssertEqual(action.title, "Agent action · spawnAgent")
        XCTAssertEqual(action.status, "inProgress")
        XCTAssertEqual(CodexSubagentCardInfo(item: .other(id: "new", type: "newItem")).title,
                       "Other item · newItem")
    }

    @MainActor
    func testProtocolDecodesOfficialMCPAndCollaborationItems() throws {
        let json = """
        {
          "id":"child-thread","historyMode":"legacy",
          "turns":[{
            "id":"turn-1","status":"completed","items":[
              {"id":"u","type":"userMessage","content":[{"type":"text","text":"inspect"}]},
              {"id":"m","type":"mcpToolCall","server":"github","tool":"search",
               "status":"completed","arguments":{"query":"code"},"result":{"ok":true}},
              {"id":"a","type":"collabAgentToolCall","tool":"spawnAgent",
               "status":"inProgress","receiverThreadIds":["child-2"],"prompt":"inspect"}
            ]
          }]
        }
        """
        let decoded = try JSONDecoder().decode(ThreadReadThreadPayload.self, from: Data(json.utf8))
        let detail = AppServerClient().convertThread(decoded)
        XCTAssertEqual(detail.turns.count, 1)
        XCTAssertEqual(detail.turns[0].items.count, 3)
        guard case .toolCall(_, let name, let status, let details) = detail.turns[0].items[1] else {
            return XCTFail("Expected typed MCP tool")
        }
        XCTAssertEqual(name, "github / search")
        XCTAssertEqual(status, "completed")
        XCTAssertTrue(details?.contains("query") == true)
        guard case .agentAction(_, let tool, _, _) = detail.turns[0].items[2] else {
            return XCTFail("Expected typed collaboration tool")
        }
        XCTAssertEqual(tool, "spawnAgent")
    }
}


final class WorkspaceFilesAndWorktreesTests: XCTestCase {
    func testWorkspacePathsCannotEscapeAndRequireAbsoluteLinuxRoot() {
        XCTAssertEqual(CodexWorkspacePathPolicy.normalizedRoot("/home/dev/repo/"), "/home/dev/repo")
        XCTAssertNil(CodexWorkspacePathPolicy.normalizedRoot("relative/path"))
        XCTAssertEqual(CodexWorkspacePathPolicy.childPath(directory: "/home/dev/repo", name: "src", root: "/home/dev/repo"),
                       "/home/dev/repo/src")
        for name in ["..", ".", "../secret", "/etc/passwd", "bad\\name", ""] {
            XCTAssertNil(CodexWorkspacePathPolicy.childPath(directory: "/home/dev/repo", name: name,
                                                              root: "/home/dev/repo"), name)
        }
        XCTAssertFalse(CodexWorkspacePathPolicy.contains(path: "/home/dev/repo-elsewhere/file", root: "/home/dev/repo"))
    }

    func testReadOnlyPreviewNeedsReportedBoundedSize() {
        XCTAssertFalse(CodexWorkspacePathPolicy.canPreview(sizeBytes: nil))
        XCTAssertFalse(CodexWorkspacePathPolicy.canPreview(sizeBytes: -1))
        XCTAssertTrue(CodexWorkspacePathPolicy.canPreview(sizeBytes: 42))
        XCTAssertTrue(CodexWorkspacePathPolicy.canPreview(sizeBytes: 512 * 1024))
        XCTAssertFalse(CodexWorkspacePathPolicy.canPreview(sizeBytes: 512 * 1024 + 1))
    }

    func testGitPorcelainWorktreesPreserveDetachedAndLockedMetadata() {
        let sample = """
        worktree /srv/repo
        HEAD 01234567
        branch refs/heads/main

        worktree /srv/wt/feature
        HEAD 89abcdef
        branch refs/heads/feature
        locked moving

        worktree /srv/wt/review
        HEAD fedcba98
        detached

        """
        let trees = SSHGitService.parseWorktrees(sample)
        XCTAssertEqual(trees.count, 3)
        XCTAssertEqual(trees[0].branch, "main")
        XCTAssertEqual(trees[1].branch, "feature")
        XCTAssertTrue(trees[1].isLocked)
        XCTAssertTrue(trees[2].isDetached)
        XCTAssertNil(trees[2].branch)
    }
}
