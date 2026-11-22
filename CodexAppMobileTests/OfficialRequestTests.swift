import XCTest
@testable import CodexAppMobile

final class OfficialRequestTests: XCTestCase {
    func testPermissionResponsePreservesGrantedProfileAndScope() throws {
        let profile: JSONValue = .object([
            "network": .object(["enabled": .bool(true)]),
            "fileSystem": .object([
                "read": .array([.string("/workspace/docs")]),
                "write": .array([.string("/workspace/output")]),
            ]),
        ])
        let approval = AppServerPermissionApproval(profile: profile, cwd: "/workspace", reason: "Build documentation")
        XCTAssertTrue(approval.canGrant)
        XCTAssertEqual(try approval.response(grant: true, scope: .session), .object([
            "permissions": profile,
            "scope": .string("session"),
        ]))
        XCTAssertEqual(try approval.response(grant: false, scope: .session), .object([
            "permissions": .object([:]),
            "scope": .string("turn"),
        ]))
    }

    func testUnknownPermissionCannotBeGrantedButCanBeDenied() throws {
        let approval = AppServerPermissionApproval(
            profile: .object([
                "network": .object(["enabled": .bool(true)]),
                "unrecognizedAccess": .bool(true),
            ]),
            cwd: nil,
            reason: nil
        )
        XCTAssertFalse(approval.canGrant)
        XCTAssertNotNil(approval.unsupportedReason)
        XCTAssertThrowsError(try approval.response(grant: true))
        XCTAssertEqual(try approval.response(grant: false)["permissions"], .object([:]))
    }

    func testModernFilesystemEntriesAreDisplayedAndPreserved() throws {
        let entries: JSONValue = .array([
            .object([
                "path": .object(["type": .string("path"), "path": .string("/workspace/source")]),
                "access": .string("read"),
            ]),
            .object([
                "path": .object(["type": .string("glob_pattern"), "pattern": .string("/workspace/output/**")]),
                "access": .string("write"),
            ]),
            .object([
                "path": .object(["type": .string("path"), "path": .string("/workspace/.secrets")]),
                "access": .string("deny"),
            ]),
        ])
        let profile: JSONValue = .object([
            "fileSystem": .object([
                "read": .null,
                "write": .null,
                "entries": entries,
                "globScanMaxDepth": .number(3),
            ]),
        ])
        let approval = AppServerPermissionApproval(profile: profile, cwd: nil, reason: nil)
        XCTAssertTrue(approval.canGrant)
        XCTAssertTrue(approval.summaryLines.contains { $0.contains("/workspace/source") })
        XCTAssertTrue(approval.summaryLines.contains { $0.contains("/workspace/output/**") })
        XCTAssertTrue(approval.summaryLines.contains { $0.contains("/workspace/.secrets") })
        XCTAssertEqual(try approval.response(grant: true)["permissions"], profile)
    }

    func testUnrecognizedNestedPermissionDoesNotDisappearIntoAnApproval() {
        let invalidProfiles: [JSONValue] = [
            .object(["network": .object(["enabled": .bool(true), "extra": .bool(true)])]),
            .object(["network": .object(["enabled": .string("true")])]),
            .object(["fileSystem": .object(["read": .array([.number(12)])])]),
            .object(["fileSystem": .object(["globScanMaxDepth": .number(0)])]),
            .object(["fileSystem": .object(["entries": .array([
                .object([
                    "path": .object(["type": .string("future_path"), "path": .string("/")]),
                    "access": .string("write"),
                ]),
            ])])]),
        ]
        for profile in invalidProfiles {
            XCTAssertFalse(AppServerPermissionApproval(profile: profile, cwd: nil, reason: nil).canGrant)
        }
    }

    func testExplicitFilesystemRootIsNotRenderedAsOneAnonymousPath() {
        let approval = AppServerPermissionApproval(profile: .object([
            "fileSystem": .object(["entries": .array([
                .object([
                    "path": .object([
                        "type": .string("special"),
                        "value": .object(["kind": .string("root")]),
                    ]),
                    "access": .string("write"),
                ]),
            ])]),
        ]), cwd: nil, reason: nil)
        XCTAssertTrue(approval.canGrant)
        XCTAssertTrue(approval.summaryLines.contains { $0.contains(L10n.text("Entire filesystem")) })
    }

    @MainActor
    func testPermissionRequestKeepsRPCAndThreadIdentity() throws {
        let request = try self.parse(method: "item/permissions/requestApproval", params: [
            "threadId": .string("parent-1"),
            "turnId": .string("turn-2"),
            "itemId": .string("item-3"),
            "permissions": .object(["network": .object(["enabled": .bool(true)])]),
        ])
        XCTAssertEqual(request.rpcID, .string("approval-42"))
        XCTAssertEqual(request.threadID, "parent-1")
        XCTAssertEqual(request.turnID, "turn-2")
        XCTAssertEqual(request.itemID, "item-3")
        guard case .permissionsApproval(let approval) = request.kind else {
            return XCTFail("Expected an explicit permission approval.")
        }
        XCTAssertTrue(approval.canGrant)
    }

    @MainActor
    func testHumanCheckpointNeverOffersOrAcceptsSessionApproval() throws {
        let request = try self.parse(method: "item/commandExecution/requestApproval", params: [
            "kind": .string("humanCommand"),
            "command": .string("deploy"),
        ])
        guard case .commandApproval(_, _, _, let choices, _, _, _, _) = request.kind else {
            return XCTFail("Expected human checkpoint.")
        }
        XCTAssertEqual(choices, [.accept, .decline, .cancel])
        XCTAssertNoThrow(try AppServerClient.validateOfficialCommandDecision(request: request, decision: .accept))
        XCTAssertThrowsError(try AppServerClient.validateOfficialCommandDecision(request: request, decision: .acceptForSession))
        XCTAssertThrowsError(try AppServerClient.validateOfficialCommandDecision(
            request: request,
            decision: .acceptWithExecpolicyAmendment(amendment: AppServerExecPolicyAmendment(command: ["deploy"]))
        ))
    }

    @MainActor
    func testCommandApprovalPreservesModernAdditionalAccessDetails() throws {
        let profile: JSONValue = .object([
            "fileSystem": .object(["entries": .array([
                .object([
                    "path": .object(["type": .string("path"), "path": .string("/workspace/output")]),
                    "access": .string("write"),
                ]),
            ])]),
        ])
        let request = try self.parse(method: "item/commandExecution/requestApproval", params: [
            "additionalPermissions": profile,
        ])
        XCTAssertEqual(request.additionalPermissionProfile?.profile, profile)
        XCTAssertTrue(request.additionalPermissionProfile?.summaryLines.contains {
            $0.contains("/workspace/output")
        } == true)
        XCTAssertNoThrow(try AppServerClient.validateOfficialCommandDecision(request: request, decision: .accept))
    }

    @MainActor
    func testCommandCannotGrantUnrepresentedAdditionalAccess() throws {
        let request = try self.parse(method: "item/commandExecution/requestApproval", params: [
            "additionalPermissions": .object(["futureAccess": .bool(true)]),
        ])
        XCTAssertEqual(request.additionalPermissionProfile?.canGrant, false)
        XCTAssertThrowsError(try AppServerClient.validateOfficialCommandDecision(request: request, decision: .accept))
        XCTAssertNoThrow(try AppServerClient.validateOfficialCommandDecision(request: request, decision: .decline))
    }

    @MainActor
    func testAdvertisedCommandChoicesAreNotBroadened() throws {
        let request = try self.parse(method: "item/commandExecution/requestApproval", params: [
            "availableDecisions": .array([.string("decline"), .string("cancel")]),
        ])
        XCTAssertThrowsError(try AppServerClient.validateOfficialCommandDecision(request: request, decision: .accept))
        XCTAssertNoThrow(try AppServerClient.validateOfficialCommandDecision(request: request, decision: .decline))
    }

    @MainActor
    func testUnknownAdvertisedChoicesDoNotFallBackToAccept() throws {
        let decisionLists: [[JSONValue]] = [[], [.string("acceptAlways")]]
        for choices in decisionLists {
            let request = try self.parse(method: "item/commandExecution/requestApproval", params: [
                "availableDecisions": .array(choices),
            ])
            XCTAssertEqual(request.kind, .unknown)
            XCTAssertThrowsError(try AppServerClient.validateOfficialCommandDecision(request: request, decision: .accept))
        }
    }

    @MainActor
    func testHumanCheckpointRejectsOnlyInapplicableAdvertisedChoices() throws {
        let request = try self.parse(method: "item/commandExecution/requestApproval", params: [
            "kind": .string("humanCommand"),
            "availableDecisions": .array([.string("acceptForSession")]),
        ])
        XCTAssertEqual(request.kind, .unknown)
    }

    @MainActor
    func testUserInputMetadataAndLiteralSecretAnswerArePreserved() throws {
        let request = try self.parse(method: "item/tool/requestUserInput", params: [
            "isBlocking": .bool(false),
            "questions": .array([.object([
                "id": .string("credential"),
                "header": .string("Credential"),
                "question": .string("Enter the value"),
                "isSecret": .bool(true),
                "isOther": .bool(true),
                "options": .null,
            ])]),
        ])
        XCTAssertFalse(request.isBlocking)
        guard case .userInput(let questions) = request.kind else { return XCTFail("Expected input.") }
        XCTAssertEqual(questions.first?.header, "Credential")
        XCTAssertEqual(questions.first?.isSecret, true)
        XCTAssertEqual(questions.first?.isOther, true)
        let literal = "alpha,beta\nsecond line"
        let answers = try AppServerClient.makeOfficialUserInputAnswers(questions: questions, values: [
            "credential": literal,
        ])
        XCTAssertEqual(answers, ["credential": [literal]])
        XCTAssertNoThrow(try AppServerClient.validateOfficialUserInput(request: request, answers: answers))
    }

    @MainActor
    func testUnansweredQuestionIsNotReplacedWithFirstChoice() throws {
        let request = try self.inputRequest(isOther: false)
        guard case .userInput(let questions) = request.kind else { return XCTFail("Expected input.") }
        XCTAssertThrowsError(try AppServerClient.makeOfficialUserInputAnswers(questions: questions, values: [:]))
        XCTAssertThrowsError(try AppServerClient.makeOfficialUserInputAnswers(questions: questions, values: ["choice": ""]))
        XCTAssertEqual(
            try AppServerClient.makeOfficialUserInputAnswers(questions: questions, values: ["choice": "A, B"]),
            ["choice": ["A, B"]]
        )
    }

    @MainActor
    func testOtherAnswerRequiresTheQuestionToAllowIt() throws {
        let closed = try self.inputRequest(isOther: false)
        let open = try self.inputRequest(isOther: true)
        XCTAssertThrowsError(try AppServerClient.validateOfficialUserInput(request: closed, answers: [
            "choice": ["Custom answer"],
        ]))
        XCTAssertNoThrow(try AppServerClient.validateOfficialUserInput(request: open, answers: [
            "choice": ["Custom answer"],
        ]))
        XCTAssertThrowsError(try AppServerClient.validateOfficialUserInput(request: open, answers: [
            "unrelated-question": ["Custom answer"],
        ]))
    }

    @MainActor
    func testOlderInputDefaultsToBlockingAndRetainsAliases() throws {
        let request = try self.parse(method: "tool/request_user_input", params: [
            "questions": .array([.object([
                "questionId": .string("directory"),
                "prompt": .string("Allow access?"),
                "choices": .array([.object([
                    "title": .string("Allow"),
                    "helpText": .string("Use this directory."),
                ])]),
            ])]),
        ])
        XCTAssertTrue(request.isBlocking)
        guard case .userInput(let questions) = request.kind else { return XCTFail("Expected input.") }
        XCTAssertEqual(questions.first?.id, "directory")
        XCTAssertEqual(questions.first?.options.first?.label, "Allow")
    }

    @MainActor
    private func inputRequest(isOther: Bool) throws -> AppServerPendingRequest {
        try self.parse(method: "item/tool/requestUserInput", params: [
            "questions": .array([.object([
                "id": .string("choice"),
                "header": .string("Choice"),
                "question": .string("Choose an option"),
                "isOther": .bool(isOther),
                "options": .array([.object([
                    "label": .string("A, B"),
                    "description": .string("One option with a comma."),
                ])]),
            ])]),
        ])
    }

    @MainActor
    private func parse(method: String, params: [String: JSONValue]) throws -> AppServerPendingRequest {
        try XCTUnwrap(AppServerClient.parseOfficialRequest(
            id: .string("approval-42"),
            method: method,
            params: params
        ))
    }
}

