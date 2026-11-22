import Foundation
import UniformTypeIdentifiers

enum CodexWorkspaceToolError: LocalizedError, Equatable {
    case invalidPath
    case outsideWorkspace
    case symbolicLink
    case wrongFileType
    case fileTooLarge
    case fileChanged
    case invalidFileData
    case incompleteOutput
    case invalidWorktreeList
    case invalidBranch
    case protectedWorktree(String)
    case dirtyWorktree
    case commandFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidPath: "Use an absolute Unix path without dot components or NUL characters."
        case .outsideWorkspace: "This path is outside the selected workspace."
        case .symbolicLink: "Symbolic links are not opened by the workspace browser."
        case .wrongFileType: "This path is not a regular file or directory of the expected type."
        case .fileTooLarge: "This file exceeds the 2 MiB preview limit."
        case .fileChanged: "The file changed while it was being read. Refresh to try again."
        case .invalidFileData: "The server returned invalid file data."
        case .incompleteOutput: "The command output is incomplete or exceeds its size limit."
        case .invalidWorktreeList: "Git returned an invalid or incomplete worktree list."
        case .invalidBranch: "Enter a new branch name without spaces or revision expressions."
        case .protectedWorktree(let reason): reason
        case .dirtyWorktree: "This worktree contains modified, untracked or ignored files. Keep or move them before removing it."
        case .commandFailed(let code, let message): "Command failed (\(code)). \(message)"
        }
    }
}

enum CodexWorkspacePath {
    static func absolute(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw CodexWorkspaceToolError.invalidPath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains("."), !parts.contains("..") else { throw CodexWorkspaceToolError.invalidPath }
        return "/" + parts.joined(separator: "/")
    }

    static func child(_ name: String, of parent: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw CodexWorkspaceToolError.invalidPath
        }
        let parent = try absolute(parent)
        return parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    static func contained(_ path: String, in root: String) throws -> String {
        let path = try absolute(path)
        let root = try absolute(root)
        guard root == "/" || path == root || path.hasPrefix(root + "/") else {
            throw CodexWorkspaceToolError.outsideWorkspace
        }
        return path
    }

    static func traversal(_ path: String, root: String) throws -> [String] {
        let root = try absolute(root)
        let path = try contained(path, in: root)
        if path == root { return [root] }
        let relative = path.dropFirst(root == "/" ? 1 : root.count + 1)
        var result = [root]
        for component in relative.split(separator: "/") {
            result.append(try child(String(component), of: result.last!))
        }
        return result
    }

    static func name(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

struct CodexRemoteFileMetadata: Decodable, Equatable {
    let isDirectory: Bool
    let isFile: Bool
    let isSymlink: Bool
}

struct CodexRemoteFileEntry: Decodable, Equatable, Identifiable {
    let fileName: String
    let isDirectory: Bool
    let isFile: Bool
    var id: String { fileName }
}

struct CodexRemoteDirectoryResponse: Decodable {
    let entries: [CodexRemoteFileEntry]
}

struct CodexRemoteFileResponse: Decodable {
    let dataBase64: String
}

struct CodexRemoteFilePreview: Equatable {
    static let maximumBytes = 2 * 1024 * 1024

    enum Content: Equatable {
        case text(String)
        case image(Data)
        case pdf(Data)
        case unsupported
    }

    let path: String
    let byteCount: Int
    let content: Content

    static func decode(path: String, base64: String, expectedSize: Int) throws -> Self {
        let maximumEncodedBytes = ((maximumBytes + 2) / 3) * 4
        guard expectedSize >= 0, expectedSize <= maximumBytes,
              base64.utf8.count <= maximumEncodedBytes else { throw CodexWorkspaceToolError.fileTooLarge }
        guard let data = Data(base64Encoded: base64) else { throw CodexWorkspaceToolError.invalidFileData }
        guard data.count <= maximumBytes else { throw CodexWorkspaceToolError.fileTooLarge }
        guard data.count == expectedSize else { throw CodexWorkspaceToolError.fileChanged }
        let content: Content
        let extensionName = (path as NSString).pathExtension
        if data.starts(with: Data("%PDF-".utf8)) {
            content = .pdf(data)
        } else if let type = UTType(filenameExtension: extensionName), type.conforms(to: .image) {
            content = .image(data)
        } else if let text = decodedText(data) {
            content = .text(text)
        } else {
            content = .unsupported
        }
        return Self(path: path, byteCount: data.count, content: content)
    }

    private static func decodedText(_ data: Data) -> String? {
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else {
            text = String(data: data, encoding: .utf8)
        }
        guard let text, !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 12, 13].contains($0.value) }) else {
            return nil
        }
        return text
    }
}

struct CodexWorkspaceCommandResult: Decodable, Equatable {
    let exitCode: Int
    let stdout: String
    let stderr: String
}

struct CodexGitWorktree: Identifiable, Equatable {
    let path: String
    let head: String?
    let branch: String?
    let isMain: Bool
    let isCurrent: Bool
    let isBare: Bool
    let isDetached: Bool
    let lockedReason: String?
    let prunableReason: String?
    let hasUnknownAttributes: Bool
    var id: String { path }

    var removalBlockReason: String? {
        if isMain { return "The main worktree cannot be removed." }
        if isCurrent { return "The current workspace cannot be removed." }
        if isBare { return "A bare repository cannot be removed here." }
        if lockedReason != nil { return "This worktree is locked." }
        if prunableReason != nil { return "This worktree needs Git maintenance before removal." }
        if hasUnknownAttributes { return "This worktree has metadata this client cannot safely interpret." }
        return nil
    }

    var canOpen: Bool { !isBare && prunableReason == nil }

    static func parse(_ output: String, currentPath: String) throws -> [Self] {
        guard !output.isEmpty, output.hasSuffix("\0\0") else { throw CodexWorkspaceToolError.invalidWorktreeList }
        let current = try CodexWorkspacePath.absolute(currentPath)
        var records: [[String]] = []
        var record: [String] = []
        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty {
                if !record.isEmpty { records.append(record); record = [] }
            } else {
                record.append(String(field))
            }
        }
        guard !records.isEmpty else { throw CodexWorkspaceToolError.invalidWorktreeList }
        var paths = Set<String>()
        return try records.enumerated().map { index, fields in
            guard let first = fields.first, first.hasPrefix("worktree ") else { throw CodexWorkspaceToolError.invalidWorktreeList }
            let path = try CodexWorkspacePath.absolute(String(first.dropFirst(9)))
            guard paths.insert(path).inserted else { throw CodexWorkspaceToolError.invalidWorktreeList }
            var values: [String: String] = [:]
            for field in fields.dropFirst() {
                let components = field.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(components[0])
                guard key != "worktree", values[key] == nil else { throw CodexWorkspaceToolError.invalidWorktreeList }
                values[key] = components.count == 2 ? String(components[1]) : ""
            }
            let bare = values["bare"] != nil
            guard bare || values["HEAD"]?.isEmpty == false else { throw CodexWorkspaceToolError.invalidWorktreeList }
            let known: Set<String> = ["HEAD", "branch", "bare", "detached", "locked", "prunable"]
            return Self(
                path: path, head: values["HEAD"], branch: values["branch"], isMain: index == 0,
                isCurrent: path == current, isBare: bare, isDetached: values["detached"] != nil,
                lockedReason: values["locked"], prunableReason: values["prunable"],
                hasUnknownAttributes: !Set(values.keys).isSubset(of: known)
            )
        }
    }
}
