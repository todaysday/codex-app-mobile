import XCTest
@testable import CodexAppMobile

final class CodexWorkspaceToolsTests: XCTestCase {
    func testWorkspacePathsPreserveNamesAndRejectEscapes() throws {
        XCTAssertEqual(try CodexWorkspacePath.child("a\n$(literal).swift", of: "/repo"), "/repo/a\n$(literal).swift")
        XCTAssertEqual(try CodexWorkspacePath.traversal("/repo/src/main.swift", root: "/repo"), ["/repo", "/repo/src", "/repo/src/main.swift"])
        XCTAssertEqual(try CodexWorkspacePath.contained("/anywhere", in: "/"), "/anywhere")
        XCTAssertThrowsError(try CodexWorkspacePath.contained("/repository/file", in: "/repo"))
        for path in ["relative", "~/repo", "/repo/../secret", "/repo/./file", "/repo/\0"] {
            XCTAssertThrowsError(try CodexWorkspacePath.absolute(path))
        }
        for name in ["", ".", "..", "sub/file", "/root", "a\0b"] {
            XCTAssertThrowsError(try CodexWorkspacePath.child(name, of: "/repo"))
        }
    }

    func testPreviewDecodesUnicodeTextAndUTF16() throws {
        let text = "let greeting = \"Привет 👋\"\n"
        for encoding in [String.Encoding.utf8, .utf16] {
            let data = try XCTUnwrap(text.data(using: encoding))
            let preview = try CodexRemoteFilePreview.decode(path: "/repo/a.swift", base64: data.base64EncodedString(), expectedSize: data.count)
            XCTAssertEqual(preview.content, .text(text))
            XCTAssertEqual(preview.byteCount, data.count)
        }
    }

    func testPreviewRejectsInvalidBase64OversizeAndChangingFiles() throws {
        XCTAssertThrowsError(try CodexRemoteFilePreview.decode(path: "/repo/a", base64: "not base64", expectedSize: 4))
        XCTAssertThrowsError(try CodexRemoteFilePreview.decode(path: "/repo/a", base64: "YQ==", expectedSize: 2)) { error in
            XCTAssertEqual(error as? CodexWorkspaceToolError, .fileChanged)
        }
        let oversized = CodexRemoteFilePreview.maximumBytes + 1
        XCTAssertThrowsError(try CodexRemoteFilePreview.decode(path: "/repo/a", base64: "", expectedSize: oversized))
        XCTAssertThrowsError(try CodexRemoteFilePreview.decode(path: "/repo/a", base64: String(repeating: "A", count: 3_000_000), expectedSize: 1))
    }

    func testPreviewDistinguishesPDFImageAndBinary() throws {
        let pdf = Data("%PDF-1.7\n".utf8)
        XCTAssertEqual(try CodexRemoteFilePreview.decode(path: "/repo/no-extension", base64: pdf.base64EncodedString(), expectedSize: pdf.count).content, .pdf(pdf))
        let png = Data([137, 80, 78, 71])
        XCTAssertEqual(try CodexRemoteFilePreview.decode(path: "/repo/photo.png", base64: png.base64EncodedString(), expectedSize: png.count).content, .image(png))
        let binary = Data([0, 1, 2, 3])
        XCTAssertEqual(try CodexRemoteFilePreview.decode(path: "/repo/data.bin", base64: binary.base64EncodedString(), expectedSize: binary.count).content, .unsupported)
        XCTAssertEqual(try CodexRemoteFilePreview.decode(path: "/repo/empty.txt", base64: "", expectedSize: 0).content, .text(""))
    }

    func testWorktreePorcelainPreservesNULDelimitedPathsAndFlags() throws {
        let output = Self.record("/repo", branch: "refs/heads/main")
            + Self.record("/linked/line\nbreak", branch: nil, extra: ["detached", "locked Maintenance\nwindow"])
            + Self.record("/gone", branch: "refs/heads/old", extra: ["prunable missing directory"])
        let parsed = try CodexGitWorktree.parse(output, currentPath: "/linked/line\nbreak")
        XCTAssertEqual(parsed.count, 3)
        XCTAssertTrue(parsed[0].isMain)
        XCTAssertFalse(parsed[0].isCurrent)
        XCTAssertEqual(parsed[1].path, "/linked/line\nbreak")
        XCTAssertEqual(parsed[1].lockedReason, "Maintenance\nwindow")
        XCTAssertTrue(parsed[1].isCurrent)
        XCTAssertTrue(parsed[1].isDetached)
        XCTAssertFalse(parsed[2].canOpen)
    }

    func testWorktreeParserRejectsTruncationDuplicatePathsAndMissingHead() {
        for output in ["", "\0\0", "worktree /repo\0HEAD abc\0", "worktree /repo\0\0", Self.record("/repo") + Self.record("/repo")] {
            XCTAssertThrowsError(try CodexGitWorktree.parse(output, currentPath: "/repo"))
        }
    }

    func testBareAndUnknownWorktreeMetadataBlockRemoval() throws {
        let parsed = try CodexGitWorktree.parse("worktree /bare\0bare\0\0" + Self.record("/linked", extra: ["futureSafetyFlag yes"]), currentPath: "/elsewhere")
        XCTAssertFalse(parsed[0].canOpen)
        XCTAssertTrue(parsed[0].isBare)
        XCTAssertNotNil(parsed[0].removalBlockReason)
        XCTAssertNotNil(parsed[1].removalBlockReason)
    }

    @MainActor
    func testDirectoryUsesOfficialMethodsAndSortsDirectoriesFirst() async throws {
        let (client, host) = Self.connection()
        var methods: [String] = []
        client.requestOverrideForTesting = { method, params in
            methods.append(method)
            XCTAssertEqual(params, .object(["path": .string("/repo")]))
            if method == "fs/getMetadata" { return Self.metadata(directory: true) }
            return .object(["entries": .array([
                .object(["fileName": .string("z.txt"), "isDirectory": .bool(false), "isFile": .bool(true)]),
                .object(["fileName": .string("src"), "isDirectory": .bool(true), "isFile": .bool(false)]),
            ])])
        }
        let entries = try await client.workspaceReadDirectory(hostID: host.id, root: "/repo", path: "/repo")
        XCTAssertEqual(entries.map(\.fileName), ["src", "z.txt"])
        XCTAssertEqual(methods, ["fs/getMetadata", "fs/readDirectory"])
    }

    @MainActor
    func testDirectoryRejectsUnsafeServerChildNames() async {
        let (client, host) = Self.connection()
        client.requestOverrideForTesting = { method, _ in
            if method == "fs/getMetadata" { return Self.metadata(directory: true) }
            return .object(["entries": .array([
                .object(["fileName": .string("../secret"), "isDirectory": .bool(false), "isFile": .bool(true)]),
            ])])
        }
        await expect(.invalidPath) { try await client.workspaceReadDirectory(hostID: host.id, root: "/repo", path: "/repo") }
    }

    @MainActor
    func testSymlinkAncestorStopsPreviewBeforeSizeOrRead() async {
        let (client, host) = Self.connection()
        var paths: [String] = []
        client.requestOverrideForTesting = { method, params in
            XCTAssertEqual(method, "fs/getMetadata")
            let path = params?["path"]?.stringValue ?? ""
            paths.append(path)
            return Self.metadata(directory: true, symlink: path == "/repo/link")
        }
        await expect(.symbolicLink) { try await client.workspacePreviewFile(hostID: host.id, root: "/repo", path: "/repo/link/file") }
        XCTAssertEqual(paths, ["/repo", "/repo/link"])
    }

    @MainActor
    func testPreviewUsesBoundedCountAndOfficialFullReadWithoutSSH() async throws {
        let (client, host) = Self.connection()
        let path = "/repo/a $(literal).swift"
        let bytes = Data("hello".utf8)
        var methods: [String] = []
        client.requestOverrideForTesting = { method, params in
            methods.append(method)
            switch method {
            case "fs/getMetadata": return Self.metadata(directory: params?["path"] == .string("/repo"))
            case "command/exec":
                XCTAssertEqual(Self.argv(params), ["wc", "-c", "--", path])
                XCTAssertEqual(params?["timeoutMs"], .number(10_000))
                XCTAssertEqual(params?["outputBytesCap"], .number(4096))
                Self.assertNoPermissionOverrides(params)
                return Self.command("5 \(path)\n")
            case "fs/readFile":
                XCTAssertEqual(params, .object(["path": .string(path)]))
                return .object(["dataBase64": .string(bytes.base64EncodedString())])
            default: throw AppServerClientError.malformedResponse
            }
        }
        let preview = try await client.workspacePreviewFile(hostID: host.id, root: "/repo", path: path)
        XCTAssertEqual(preview.content, .text("hello"))
        XCTAssertEqual(methods, ["fs/getMetadata", "fs/getMetadata", "command/exec", "fs/getMetadata", "fs/readFile"])
        XCTAssertEqual(host.host, "")
    }

    @MainActor
    func testOversizedPreviewNeverReadsFileContents() async {
        let (client, host) = Self.connection()
        var didRead = false
        client.requestOverrideForTesting = { method, params in
            if method == "fs/getMetadata" { return Self.metadata(directory: params?["path"] == .string("/repo")) }
            if method == "command/exec" { return Self.command("\(CodexRemoteFilePreview.maximumBytes + 1) /repo/file\n") }
            didRead = true
            return .null
        }
        await expect(.fileTooLarge) { try await client.workspacePreviewFile(hostID: host.id, root: "/repo", path: "/repo/file") }
        XCTAssertFalse(didRead)
    }

    @MainActor
    func testSizeCommandFailureDoesNotFallBackToUnboundedRead() async {
        let (client, host) = Self.connection()
        var didRead = false
        client.requestOverrideForTesting = { method, params in
            if method == "fs/getMetadata" { return Self.metadata(directory: params?["path"] == .string("/repo")) }
            if method == "command/exec" { return Self.command("", code: 127, stderr: "wc unavailable") }
            didRead = true
            return .null
        }
        await expect(.commandFailed(127, "wc unavailable")) { try await client.workspacePreviewFile(hostID: host.id, root: "/repo", path: "/repo/file") }
        XCTAssertFalse(didRead)
    }

    @MainActor
    func testHostSwitchDuringSizePreflightStopsFollowingFileRequests() async {
        let (client, host) = Self.connection()
        var calls = 0
        client.requestOverrideForTesting = { method, params in
            calls += 1
            if method == "fs/getMetadata" { return Self.metadata(directory: params?["path"] == .string("/repo")) }
            client.setStateForTesting(.connected, host: Self.host())
            return Self.command("5 /repo/file\n")
        }
        do {
            _ = try await client.workspacePreviewFile(hostID: host.id, root: "/repo", path: "/repo/file")
            XCTFail("Must reject a result from the previous host")
        } catch {
            guard case CodexOfficialError.connectionChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(calls, 3)
    }

    @MainActor
    func testReconnectDuringTraversalInvalidatesOldGeneration() async {
        let (client, host) = Self.connection()
        var calls = 0
        client.requestOverrideForTesting = { _, _ in
            calls += 1
            client.disconnect()
            client.setStateForTesting(.connected, host: host)
            return Self.metadata(directory: true)
        }
        do {
            _ = try await client.workspaceReadDirectory(hostID: host.id, root: "/repo", path: "/repo/src")
            XCTFail("Must reject the previous connection generation")
        } catch {
            guard case CodexOfficialError.connectionChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testUnsupportedFilesystemMethodIsReportedAndCached() async {
        let (client, host) = Self.connection()
        var requests = 0
        client.requestOverrideForTesting = { _, _ in
            requests += 1
            throw AppServerClientError.remote(code: -32601, message: "Method not found")
        }
        for _ in 0..<2 {
            do {
                _ = try await client.workspaceReadDirectory(hostID: host.id, root: "/repo", path: "/repo")
                XCTFail("Should report unsupported")
            } catch {
                guard case CodexOfficialError.unsupported(let method) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(method, "fs/getMetadata")
            }
        }
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testWorktreeListKeepsNewlinePathFromGitToplevel() async throws {
        let (client, host) = Self.connection()
        let path = "/repo/line\nbreak\n"
        client.requestOverrideForTesting = { method, params in
            XCTAssertEqual(method, "command/exec")
            Self.assertNoPermissionOverrides(params)
            if Self.argv(params).contains("rev-parse") { return Self.command(path + "\n") }
            XCTAssertEqual(Self.argv(params), ["git", "-C", path, "worktree", "list", "--porcelain", "-z"])
            return Self.command(Self.record(path))
        }
        let records = try await client.workspaceWorktrees(hostID: host.id, workspacePath: path)
        XCTAssertEqual(records.first?.path, path)
        XCTAssertEqual(records.first?.isCurrent, true)
    }

    @MainActor
    func testWorktreeListRejectsCappedOutput() async {
        let (client, host) = Self.connection()
        client.requestOverrideForTesting = { _, params in
            if Self.argv(params).contains("rev-parse") { return Self.command("/repo\n") }
            return Self.command(String(repeating: "x", count: 262_144))
        }
        await expect(.incompleteOutput) { try await client.workspaceWorktrees(hostID: host.id, workspacePath: "/repo") }
    }

    @MainActor
    func testCreateUsesExactArgvAndDoesNotOverrideSandbox() async throws {
        let (client, host) = Self.connection()
        let destination = "/projects/feature $(literal)"
        var commands: [[String]] = []
        client.requestOverrideForTesting = { method, params in
            XCTAssertEqual(method, "command/exec")
            commands.append(Self.argv(params))
            XCTAssertEqual(params?["cwd"], .string("/repo"))
            XCTAssertEqual(params?["timeoutMs"], .number(20_000))
            Self.assertNoPermissionOverrides(params)
            return Self.command("")
        }
        try await client.workspaceCreateWorktree(hostID: host.id, workspacePath: "/repo", destination: destination, branch: "feature/mobile")
        XCTAssertEqual(commands, [
            ["git", "-C", "/repo", "check-ref-format", "--branch", "feature/mobile"],
            ["git", "-C", "/repo", "worktree", "add", "-b", "feature/mobile", "--", destination, "HEAD"],
        ])
    }

    @MainActor
    func testInvalidBranchOrDestinationSendsNoCommand() async {
        let (client, host) = Self.connection()
        client.requestOverrideForTesting = { _, _ in XCTFail("Must validate before sending"); return .null }
        for branch in ["", "-b", "has space", "@{-1}", "has\0null"] {
            await expect(.invalidBranch) {
                try await client.workspaceCreateWorktree(hostID: host.id, workspacePath: "/repo", destination: "/linked", branch: branch)
            }
        }
        await expect(.invalidPath) {
            try await client.workspaceCreateWorktree(hostID: host.id, workspacePath: "/repo", destination: "../linked", branch: "feature")
        }
    }

    @MainActor
    func testServerBranchValidationFailureStopsCreate() async {
        let (client, host) = Self.connection()
        var commands: [[String]] = []
        client.requestOverrideForTesting = { _, params in
            commands.append(Self.argv(params))
            return Self.command("", code: 128, stderr: "invalid branch")
        }
        await expect(.commandFailed(128, "invalid branch")) {
            try await client.workspaceCreateWorktree(hostID: host.id, workspacePath: "/repo", destination: "/linked", branch: "a..b")
        }
        XCTAssertEqual(commands.count, 1)
    }

    @MainActor
    func testWorktreeRemovalProtectsMainCurrentLockedAndPrunable() async {
        let cases: [(String, String, String)] = [
            (Self.record("/repo") + Self.record("/linked"), "/repo", "/repo"),
            (Self.record("/repo") + Self.record("/linked"), "/linked", "/linked"),
            (Self.record("/repo") + Self.record("/linked", extra: ["locked"]), "/repo", "/linked"),
            (Self.record("/repo") + Self.record("/linked", extra: ["prunable missing"]), "/repo", "/linked"),
        ]
        for (list, current, target) in cases {
            let (client, host) = Self.connection()
            var commands: [[String]] = []
            client.requestOverrideForTesting = { _, params in
                let command = Self.argv(params)
                commands.append(command)
                if command.contains("rev-parse") { return Self.command(current + "\n") }
                return Self.command(list)
            }
            do {
                try await client.workspaceRemoveWorktree(hostID: host.id, workspacePath: current, targetPath: target)
                XCTFail("Protected worktree must remain")
            } catch {
                guard case CodexWorkspaceToolError.protectedWorktree = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(commands.count, 2)
            XCTAssertFalse(commands.contains { $0.contains("remove") || $0.contains("status") })
        }
    }

    @MainActor
    func testRemovalRejectsTrackedUntrackedAndIgnoredFiles() async {
        for status in [" M file\0", "?? new.txt\0", "!! .env\0"] {
            let (client, host) = Self.connection()
            var didRemove = false
            client.requestOverrideForTesting = { _, params in
                let command = Self.argv(params)
                if command.contains("rev-parse") { return Self.command("/repo\n") }
                if command.contains("list") { return Self.command(Self.record("/repo") + Self.record("/linked")) }
                if command.contains("status") {
                    XCTAssertTrue(command.contains("--untracked-files=all"))
                    XCTAssertTrue(command.contains("--ignored=matching"))
                    return Self.command(status)
                }
                didRemove = true
                return Self.command("")
            }
            await expect(.dirtyWorktree) {
                try await client.workspaceRemoveWorktree(hostID: host.id, workspacePath: "/repo", targetPath: "/linked")
            }
            XCTAssertFalse(didRemove)
        }
    }

    @MainActor
    func testCleanWorktreeRemovalRevalidatesAndNeverForces() async throws {
        let (client, host) = Self.connection()
        var commands: [[String]] = []
        client.requestOverrideForTesting = { _, params in
            Self.assertNoPermissionOverrides(params)
            let command = Self.argv(params)
            commands.append(command)
            if command.contains("rev-parse") { return Self.command("/repo\n") }
            if command.contains("list") { return Self.command(Self.record("/repo") + Self.record("/linked space")) }
            return Self.command("")
        }
        try await client.workspaceRemoveWorktree(hostID: host.id, workspacePath: "/repo", targetPath: "/linked space")
        XCTAssertEqual(commands.count, 4)
        XCTAssertEqual(commands.last, ["git", "-C", "/repo", "worktree", "remove", "--", "/linked space"])
        XCTAssertFalse(commands.flatMap { $0 }.contains("--force"))
        XCTAssertFalse(commands.contains { $0.contains("branch") })
    }

    @MainActor
    func testHostSwitchAfterCleanStatusDoesNotRemoveOnNewHost() async {
        let (client, host) = Self.connection()
        var didRemove = false
        client.requestOverrideForTesting = { _, params in
            let command = Self.argv(params)
            if command.contains("rev-parse") { return Self.command("/repo\n") }
            if command.contains("list") { return Self.command(Self.record("/repo") + Self.record("/linked")) }
            if command.contains("status") {
                client.setStateForTesting(.connected, host: Self.host())
                return Self.command("")
            }
            didRemove = true
            return Self.command("")
        }
        do {
            try await client.workspaceRemoveWorktree(hostID: host.id, workspacePath: "/repo", targetPath: "/linked")
            XCTFail("Must not mutate another host")
        } catch {
            guard case CodexOfficialError.connectionChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(didRemove)
    }

    @MainActor
    func testStalePresentedMutationGenerationSendsNoRPC() async {
        let (client, host) = Self.connection()
        let presentedGeneration = client.connectionGeneration
        client.disconnect()
        client.setStateForTesting(.connected, host: host)
        client.requestOverrideForTesting = { _, _ in XCTFail("An old form or confirmation must send no request"); return .null }
        do {
            try await client.workspaceCreateWorktree(
                hostID: host.id, workspacePath: "/repo", destination: "/linked", branch: "feature",
                expectedGeneration: presentedGeneration
            )
            XCTFail("Stale create must be refused")
        } catch {
            guard case CodexOfficialError.connectionChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
        do {
            try await client.workspaceRemoveWorktree(
                hostID: host.id, workspacePath: "/repo", targetPath: "/linked", expectedGeneration: presentedGeneration
            )
            XCTFail("Stale remove must be refused")
        } catch {
            guard case CodexOfficialError.connectionChanged = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    @MainActor
    private func expect<T>(_ expected: CodexWorkspaceToolError, operation: () async throws -> T) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? CodexWorkspaceToolError, expected) }
    }

    @MainActor
    private static func connection() -> (AppServerClient, RemoteHost) {
        let client = AppServerClient()
        let host = host()
        client.setStateForTesting(.connected, host: host)
        return (client, host)
    }

    private static func host() -> RemoteHost {
        RemoteHost(name: "WSS only", host: "", sshPort: 22, username: "", appServerURL: "wss://example.test/socket", preferredTransport: .appServerWS)
    }

    private static func metadata(directory: Bool = false, symlink: Bool = false) -> JSONValue {
        .object(["isDirectory": .bool(directory), "isFile": .bool(!directory), "isSymlink": .bool(symlink),
                 "createdAtMs": .number(0), "modifiedAtMs": .number(0)])
    }

    private static func command(_ stdout: String, code: Int = 0, stderr: String = "") -> JSONValue {
        .object(["exitCode": .number(Double(code)), "stdout": .string(stdout), "stderr": .string(stderr)])
    }

    private static func argv(_ params: JSONValue?) -> [String] {
        params?["command"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private static func assertNoPermissionOverrides(_ params: JSONValue?) {
        for key in ["sandboxPolicy", "permissionProfile", "env", "disableTimeout", "disableOutputCap", "streamStdin", "tty"] {
            XCTAssertNil(params?[key], key)
        }
    }

    private static func record(_ path: String, branch: String? = "refs/heads/feature", extra: [String] = []) -> String {
        var fields = ["worktree \(path)", "HEAD 0123456789abcdef"]
        if let branch { fields.append("branch \(branch)") }
        fields += extra
        return fields.joined(separator: "\0") + "\0\0"
    }
}
