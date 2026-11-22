import Foundation

extension AppServerClient {
    func workspaceReadDirectory(hostID: UUID, root: String, path: String) async throws -> [CodexRemoteFileEntry] {
        let generation = connectionGeneration
        let path = try CodexWorkspacePath.contained(path, in: root)
        let metadata = try await workspaceValidatePath(hostID: hostID, generation: generation, root: root, path: path)
        guard metadata.isDirectory else { throw CodexWorkspaceToolError.wrongFileType }
        let raw = try await workspaceToolRequest(
            hostID: hostID, generation: generation, method: "fs/readDirectory", params: .object(["path": .string(path)])
        )
        let response = try decode(raw, as: CodexRemoteDirectoryResponse.self)
        var names = Set<String>()
        for entry in response.entries {
            _ = try CodexWorkspacePath.child(entry.fileName, of: path)
            guard names.insert(entry.fileName).inserted else { throw AppServerClientError.malformedResponse }
        }
        return response.entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
    }

    func workspacePreviewFile(hostID: UUID, root: String, path: String) async throws -> CodexRemoteFilePreview {
        let generation = connectionGeneration
        let path = try CodexWorkspacePath.contained(path, in: root)
        let metadata = try await workspaceValidatePath(hostID: hostID, generation: generation, root: root, path: path)
        guard metadata.isFile, !metadata.isDirectory else { throw CodexWorkspaceToolError.wrongFileType }
        // fs/getMetadata has no size field and fs/readFile has no ranged read in the pinned official protocol.
        let sizeResult = try await workspaceCommand(
            hostID: hostID, generation: generation, cwd: root,
            command: ["wc", "-c", "--", path], outputCap: 4096, timeoutMS: 10_000
        )
        guard let first = sizeResult.stdout.split(whereSeparator: { $0.isWhitespace }).first,
              let size = Int(first), size >= 0 else { throw AppServerClientError.malformedResponse }
        guard size <= CodexRemoteFilePreview.maximumBytes else { throw CodexWorkspaceToolError.fileTooLarge }
        // A second metadata check rejects ordinary replacements after the size command.
        let current = try await workspaceMetadata(hostID: hostID, generation: generation, path: path)
        guard !current.isSymlink else { throw CodexWorkspaceToolError.symbolicLink }
        guard current.isFile, !current.isDirectory else { throw CodexWorkspaceToolError.wrongFileType }
        let raw = try await workspaceToolRequest(
            hostID: hostID, generation: generation, method: "fs/readFile", params: .object(["path": .string(path)])
        )
        let response = try decode(raw, as: CodexRemoteFileResponse.self)
        return try CodexRemoteFilePreview.decode(path: path, base64: response.dataBase64, expectedSize: size)
    }

    func workspaceWorktrees(hostID: UUID, workspacePath: String) async throws -> [CodexGitWorktree] {
        try await workspaceWorktrees(hostID: hostID, generation: connectionGeneration, workspacePath: workspacePath)
    }

    func workspaceCreateWorktree(
        hostID: UUID, workspacePath: String, destination: String, branch: String, expectedGeneration: Int? = nil
    ) async throws {
        let generation = expectedGeneration ?? connectionGeneration
        guard generation == connectionGeneration, isConnected(to: hostID) else { throw CodexOfficialError.connectionChanged }
        let workspace = try CodexWorkspacePath.absolute(workspacePath)
        let destination = try CodexWorkspacePath.absolute(destination)
        guard !branch.isEmpty, !branch.hasPrefix("-"), !branch.contains("@{"),
              !branch.contains(where: { $0.isWhitespace || $0 == "\0" }) else {
            throw CodexWorkspaceToolError.invalidBranch
        }
        _ = try await workspaceCommand(
            hostID: hostID, generation: generation, cwd: workspace,
            command: ["git", "-C", workspace, "check-ref-format", "--branch", branch], outputCap: 4096
        )
        _ = try await workspaceCommand(
            hostID: hostID, generation: generation, cwd: workspace,
            command: ["git", "-C", workspace, "worktree", "add", "-b", branch, "--", destination, "HEAD"]
        )
    }

    func workspaceRemoveWorktree(
        hostID: UUID, workspacePath: String, targetPath: String, expectedGeneration: Int? = nil
    ) async throws {
        let generation = expectedGeneration ?? connectionGeneration
        guard generation == connectionGeneration, isConnected(to: hostID) else { throw CodexOfficialError.connectionChanged }
        let workspace = try CodexWorkspacePath.absolute(workspacePath)
        let target = try CodexWorkspacePath.absolute(targetPath)
        let fresh = try await workspaceWorktrees(hostID: hostID, generation: generation, workspacePath: workspace)
        guard let worktree = fresh.first(where: { $0.path == target }) else {
            throw CodexWorkspaceToolError.protectedWorktree("This worktree is no longer in the current Git list. Refresh first.")
        }
        if let reason = worktree.removalBlockReason { throw CodexWorkspaceToolError.protectedWorktree(reason) }
        let status = try await workspaceCommand(
            hostID: hostID, generation: generation, cwd: workspace,
            command: ["git", "-C", target, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"]
        )
        guard status.stdout.isEmpty else { throw CodexWorkspaceToolError.dirtyWorktree }
        _ = try await workspaceCommand(
            hostID: hostID, generation: generation, cwd: workspace,
            command: ["git", "-C", workspace, "worktree", "remove", "--", target]
        )
    }

    private func workspaceWorktrees(hostID: UUID, generation: Int, workspacePath: String) async throws -> [CodexGitWorktree] {
        let workspace = try CodexWorkspacePath.absolute(workspacePath)
        let current = try await workspaceCommand(
            hostID: hostID, generation: generation, cwd: workspace,
            command: ["git", "-C", workspace, "rev-parse", "--show-toplevel"], outputCap: 16_384
        )
        guard current.stdout.hasSuffix("\n") else { throw AppServerClientError.malformedResponse }
        // Remove Git's one record delimiter, preserving newlines that are part of a Unix pathname.
        let currentPath = String(current.stdout.dropLast())
        let list = try await workspaceCommand(
            hostID: hostID, generation: generation, cwd: workspace,
            command: ["git", "-C", workspace, "worktree", "list", "--porcelain", "-z"]
        )
        return try CodexGitWorktree.parse(list.stdout, currentPath: currentPath)
    }

    private func workspaceValidatePath(hostID: UUID, generation: Int, root: String, path: String) async throws -> CodexRemoteFileMetadata {
        let paths = try CodexWorkspacePath.traversal(path, root: root)
        var last: CodexRemoteFileMetadata?
        for candidate in paths {
            let metadata = try await workspaceMetadata(hostID: hostID, generation: generation, path: candidate)
            guard !metadata.isSymlink else { throw CodexWorkspaceToolError.symbolicLink }
            if candidate != path, !metadata.isDirectory { throw CodexWorkspaceToolError.wrongFileType }
            last = metadata
        }
        guard let last else { throw CodexWorkspaceToolError.invalidPath }
        return last
    }

    private func workspaceMetadata(hostID: UUID, generation: Int, path: String) async throws -> CodexRemoteFileMetadata {
        let raw = try await workspaceToolRequest(
            hostID: hostID, generation: generation, method: "fs/getMetadata", params: .object(["path": .string(path)])
        )
        return try decode(raw, as: CodexRemoteFileMetadata.self)
    }

    private func workspaceCommand(
        hostID: UUID, generation: Int, cwd: String, command: [String],
        outputCap: Int = 262_144, timeoutMS: Int = 20_000
    ) async throws -> CodexWorkspaceCommandResult {
        let raw = try await workspaceToolRequest(
            hostID: hostID, generation: generation, method: "command/exec", params: .object([
                "command": .array(command.map(JSONValue.string)), "cwd": .string(try CodexWorkspacePath.absolute(cwd)),
                "timeoutMs": .number(Double(timeoutMS)), "outputBytesCap": .number(Double(outputCap)),
            ])
        )
        let result = try decode(raw, as: CodexWorkspaceCommandResult.self)
        guard result.exitCode == 0 else {
            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            throw CodexWorkspaceToolError.commandFailed(result.exitCode, String(detail.prefix(3000)))
        }
        guard result.stdout.utf8.count < outputCap, result.stderr.utf8.count < outputCap else {
            throw CodexWorkspaceToolError.incompleteOutput
        }
        return result
    }

    private func workspaceToolRequest(hostID: UUID, generation: Int, method: String, params: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        guard connectionGeneration == generation, isConnected(to: hostID) else { throw CodexOfficialError.connectionChanged }
        let result = try await officialRequest(method: method, params: params)
        try Task.checkCancellation()
        guard connectionGeneration == generation, isConnected(to: hostID) else { throw CodexOfficialError.connectionChanged }
        return result
    }
}
