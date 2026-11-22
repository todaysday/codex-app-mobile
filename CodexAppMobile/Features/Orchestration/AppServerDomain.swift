import Foundation
import SwiftUI

enum JSONValue: Codable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        default:
            return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            return Int(exactly: value)
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .string(let value):
            return Bool(value)
        default:
            return nil
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    subscript(key: String) -> JSONValue? {
        self.objectValue?[key]
    }
}

struct JSONRPCErrorPayload: Codable, Equatable {
    let code: Int
    let message: String
    let data: JSONValue?
}

struct JSONRPCEnvelope: Codable, Equatable {
    let jsonrpc: String?
    let id: JSONValue?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: JSONRPCErrorPayload?

    init(
        jsonrpc: String? = nil,
        id: JSONValue? = nil,
        method: String? = nil,
        params: JSONValue? = nil,
        result: JSONValue? = nil,
        error: JSONRPCErrorPayload? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }
}

enum AppServerClientError: LocalizedError {
    case invalidURL
    case invalidEndpointHost(String)
    case notConnected
    case timeout(method: String)
    case remote(code: Int, message: String)
    case incompatibleVersion(current: String, minimum: String)
    case malformedResponse
    case unsupportedMessage
    case invalidThreadFilters
    case incompleteHistory(method: String)
    case readOnlyThread

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return L10n.text("Invalid app-server URL. Use ws:// or wss://.")
        case .invalidEndpointHost(let host):
            return L10n.format(
                "Invalid app-server host (%@). Use a reachable host or Tailscale IP, not 0.0.0.0/localhost.",
                host
            )
        case .notConnected:
            return L10n.text("Not connected to app-server.")
        case .timeout(let method):
            return L10n.format("Request timed out: %@", method)
        case .remote(let code, let message):
            return L10n.format("Remote error [%@]: %@", "\(code)", message)
        case .incompatibleVersion(let current, let minimum):
            return L10n.format("Codex CLI version %@ is not supported. Required: %@+", current, minimum)
        case .malformedResponse:
            return L10n.text("Malformed response from app-server.")
        case .unsupportedMessage:
            return L10n.text("Unsupported message from app-server.")
        case .invalidThreadFilters:
            return L10n.text("Choose either a parent thread or an ancestor thread, not both.")
        case .incompleteHistory(let method):
            return L10n.format("The server returned incomplete history for %@. Refresh to try again; saved history has been retained.", method)
        case .readOnlyThread:
            return L10n.text("This thread does not accept direct input. Continue through its parent thread.")
        }
    }
}

actor AppServerMessageRouter {
    private var nextRequestID: Int = 1
    private struct PendingResponse {
        let continuation: CheckedContinuation<JSONValue, Error>
        let generation: Int
    }
    private var pending: [String: PendingResponse] = [:]

    func makeRequestID() -> Int {
        defer { self.nextRequestID += 1 }
        return self.nextRequestID
    }

    func storeContinuation(_ continuation: CheckedContinuation<JSONValue, Error>, for idKey: String, generation: Int = 0) {
        self.pending[idKey] = PendingResponse(continuation: continuation, generation: generation)
    }

    func removeContinuation(for idKey: String) -> CheckedContinuation<JSONValue, Error>? {
        self.pending.removeValue(forKey: idKey)?.continuation
    }

    func resolveResponse(id: JSONValue, result: JSONValue?, error: JSONRPCErrorPayload?) {
        guard let idKey = Self.idKey(from: id),
              let pending = self.pending.removeValue(forKey: idKey)
        else {
            return
        }

        if let error {
            pending.continuation.resume(throwing: AppServerClientError.remote(code: error.code, message: error.message))
            return
        }

        pending.continuation.resume(returning: result ?? .null)
    }

    func failAll(with error: Error, generation: Int? = nil) {
        let failed = self.pending.filter { generation == nil || $0.value.generation == generation }
        for (id, pending) in failed {
            self.pending.removeValue(forKey: id)
            pending.continuation.resume(throwing: error)
        }
    }

    static func idKey(from value: JSONValue) -> String? {
        switch value {
        case .string(let id):
            return id
        case .number(let id):
            return String(Int(id))
        default:
            return nil
        }
    }
}

struct AppServerExecPolicyAmendment: Equatable {
    let command: [String]
}

enum AppServerNetworkPolicyRuleAction: String, CaseIterable, Identifiable {
    case allow
    case deny

    var id: String { self.rawValue }
}

struct AppServerNetworkPolicyAmendment: Equatable {
    let host: String
    let action: AppServerNetworkPolicyRuleAction
}

struct AppServerNetworkApprovalContext: Equatable {
    let host: String
    let `protocol`: String?
}

struct AppServerAdditionalFileSystemPermissions: Equatable {
    let read: [String]?
    let write: [String]?
}

struct AppServerAdditionalPermissions: Equatable {
    let network: Bool?
    let fileSystem: AppServerAdditionalFileSystemPermissions?
}

enum AppServerCommandApprovalDecisionOption: Equatable, Identifiable {
    case accept
    case acceptForSession
    case acceptWithExecpolicyAmendment(amendment: AppServerExecPolicyAmendment?)
    case applyNetworkPolicyAmendment(amendment: AppServerNetworkPolicyAmendment?)
    case decline
    case cancel

    var id: String {
        switch self {
        case .accept:
            return "accept"
        case .acceptForSession:
            return "acceptForSession"
        case .acceptWithExecpolicyAmendment(let amendment):
            return "acceptWithExecpolicyAmendment:\(amendment?.command.joined(separator: " ") ?? "none")"
        case .applyNetworkPolicyAmendment(let amendment):
            return "applyNetworkPolicyAmendment:\(amendment?.host ?? "none"):\(amendment?.action.rawValue ?? "none")"
        case .decline:
            return "decline"
        case .cancel:
            return "cancel"
        }
    }
}

enum AppServerCommandApprovalDecisionResponse: Equatable {
    case accept
    case acceptForSession
    case acceptWithExecpolicyAmendment(amendment: AppServerExecPolicyAmendment)
    case applyNetworkPolicyAmendment(amendment: AppServerNetworkPolicyAmendment)
    case decline
    case cancel

    var jsonValue: JSONValue {
        switch self {
        case .accept:
            return .string("accept")
        case .acceptForSession:
            return .string("acceptForSession")
        case .acceptWithExecpolicyAmendment(let amendment):
            return .object([
                "acceptWithExecpolicyAmendment": .object([
                    "execpolicy_amendment": .array(
                        amendment.command.map { .string($0) }
                    )
                ])
            ])
        case .applyNetworkPolicyAmendment(let amendment):
            return .object([
                "applyNetworkPolicyAmendment": .object([
                    "network_policy_amendment": .object([
                        "host": .string(amendment.host),
                        "action": .string(amendment.action.rawValue),
                    ])
                ])
            ])
        case .decline:
            return .string("decline")
        case .cancel:
            return .string("cancel")
        }
    }
}

enum AppServerFileApprovalDecision: String, CaseIterable, Identifiable {
    case accept
    case acceptForSession
    case decline
    case cancel

    var id: String { self.rawValue }
}

struct AppServerUserInputQuestionOption: Equatable {
    let label: String
    let description: String
}

struct AppServerUserInputQuestion: Identifiable, Equatable {
    let id: String
    let prompt: String
    let options: [AppServerUserInputQuestionOption]
    let header: String?
    let isSecret: Bool
    let isOther: Bool

    init(id: String, prompt: String, options: [AppServerUserInputQuestionOption],
         header: String? = nil, isSecret: Bool = false, isOther: Bool = true) {
        self.id = id
        self.prompt = prompt
        self.options = options
        self.header = header
        self.isSecret = isSecret
        self.isOther = isOther
    }
}

enum AppServerPendingRequestKind: Equatable {
    case commandApproval(
        command: String,
        cwd: String?,
        reason: String?,
        availableDecisions: [AppServerCommandApprovalDecisionOption],
        proposedExecPolicyAmendment: AppServerExecPolicyAmendment?,
        proposedNetworkPolicyAmendments: [AppServerNetworkPolicyAmendment],
        networkApprovalContext: AppServerNetworkApprovalContext?,
        additionalPermissions: AppServerAdditionalPermissions?
    )
    case fileChange(reason: String?)
    case userInput(questions: [AppServerUserInputQuestion])
    case permissionsApproval(AppServerPermissionApproval)
    case unknown
}

struct AppServerPendingRequest: Identifiable, Equatable {
    let instanceID: UUID
    let requestIDKey: String
    let rpcID: JSONValue
    let method: String
    let threadID: String
    let turnID: String
    let itemID: String
    let kind: AppServerPendingRequestKind
    let commandKind: String
    let isBlocking: Bool
    let additionalPermissionProfile: AppServerPermissionApproval?

    init(requestIDKey: String, rpcID: JSONValue, method: String, threadID: String,
         turnID: String, itemID: String, kind: AppServerPendingRequestKind,
         commandKind: String = "command", isBlocking: Bool = true,
         additionalPermissionProfile: AppServerPermissionApproval? = nil,
         instanceID: UUID = UUID()) {
        self.instanceID = instanceID
        self.requestIDKey = requestIDKey
        self.rpcID = rpcID
        self.method = method
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.kind = kind
        self.commandKind = commandKind
        self.isBlocking = isBlocking
        self.additionalPermissionProfile = additionalPermissionProfile
    }

    var id: String { self.instanceID.uuidString }

    var title: String {
        switch self.kind {
        case .commandApproval:
            return L10n.text("Command Approval")
        case .fileChange:
            return L10n.text("File Change Approval")
        case .userInput:
            return L10n.text("User Input Required")
        case .permissionsApproval:
            return L10n.text("Permissions Approval")
        case .unknown:
            return L10n.text("Server Request")
        }
    }
}

struct AppServerThreadStatus: Codable, Equatable {
    let type: String
    let activeFlags: [String]?
}

struct RemoteThreadRecord: Equatable, Identifiable {
    let id: String
    let preview: String
    let updatedAt: Date
    let archived: Bool
    let ephemeral: Bool
    let cwd: String
    let model: String?
    let reasoningEffort: String?
    var name: String?
    let parentThreadID: String?
    let forkedFromID: String?
    let agentNickname: String?
    let agentRole: String?
    var status: AppServerThreadStatus?
    let canAcceptDirectInput: Bool?
    let historyMode: String?
    let source: JSONValue?

    init(id: String, preview: String, updatedAt: Date, archived: Bool, ephemeral: Bool,
         cwd: String, model: String?, reasoningEffort: String?, name: String? = nil,
         parentThreadID: String? = nil, forkedFromID: String? = nil, agentNickname: String? = nil,
         agentRole: String? = nil, status: AppServerThreadStatus? = nil,
         canAcceptDirectInput: Bool? = nil, historyMode: String? = nil, source: JSONValue? = nil) {
        self.id = id
        self.preview = preview
        self.updatedAt = updatedAt
        self.archived = archived
        self.ephemeral = ephemeral
        self.cwd = cwd
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.name = name
        self.parentThreadID = parentThreadID
        self.forkedFromID = forkedFromID
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.status = status
        self.canAcceptDirectInput = canAcceptDirectInput
        self.historyMode = historyMode
        self.source = source
    }
}

struct AppServerModelUpgradeInfo: Equatable {
    let model: String
    let upgradeCopy: String?
    let modelLink: String?
    let migrationMarkdown: String?
}

struct AppServerModelServiceTier: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let description: String
}

struct AppServerModelDescriptor: Equatable, Identifiable {
    let model: String
    let displayName: String
    let reasoningEffortOptions: [CodexReasoningEffortOption]
    let defaultReasoningEffort: String?
    let isDefault: Bool
    let upgradeInfo: AppServerModelUpgradeInfo?
    let availabilityNuxMessage: String?
    let description: String?
    let inputModalities: [String]
    let multiAgentVersion: String?
    let serviceTiers: [AppServerModelServiceTier]
    let defaultServiceTier: String?

    init(model: String, displayName: String, reasoningEffortOptions: [CodexReasoningEffortOption],
         defaultReasoningEffort: String?, isDefault: Bool, upgradeInfo: AppServerModelUpgradeInfo?,
         availabilityNuxMessage: String?, description: String? = nil, inputModalities: [String] = [],
         multiAgentVersion: String? = nil, serviceTiers: [AppServerModelServiceTier] = [],
         defaultServiceTier: String? = nil) {
        self.model = model
        self.displayName = displayName
        self.reasoningEffortOptions = reasoningEffortOptions
        self.defaultReasoningEffort = defaultReasoningEffort
        self.isDefault = isDefault
        self.upgradeInfo = upgradeInfo
        self.availabilityNuxMessage = availabilityNuxMessage
        self.description = description
        self.inputModalities = inputModalities
        self.multiAgentVersion = multiAgentVersion
        self.serviceTiers = serviceTiers
        self.defaultServiceTier = defaultServiceTier
    }

    var id: String { self.model }
}

struct AppServerCollaborationModeDescriptor: Equatable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let isDefault: Bool

    var normalizedID: String {
        self.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum AppServerSlashCommandKind: String {
    case newThread
    case forkThread
    case startReview
    case startPlanMode
    case showStatus
    case showMCPStatus
}

struct AppServerSlashCommandDescriptor: Equatable, Identifiable {
    let kind: AppServerSlashCommandKind
    let command: String
    let title: String
    let description: String
    let systemImage: String
    let requiresThread: Bool

    var id: String { self.command }
}

struct AppServerSkillSummary: Equatable, Identifiable {
    let name: String
    let path: String?
    let description: String?

    init(name: String, path: String?, description: String? = nil) {
        self.name = name
        self.path = path
        self.description = description
    }

    var id: String {
        if let path, !path.isEmpty {
            return path
        }
        return self.name
    }
}

struct AppServerAppSummary: Equatable, Identifiable {
    let slug: String
    let title: String

    var id: String { self.slug }
}

enum AppServerErrorCategory: String {
    case authentication
    case connection
    case permission
    case compatibility
    case protocolError
    case unknown

    var title: String {
        switch self {
        case .authentication:
            return "Authentication"
        case .connection:
            return "Connection"
        case .permission:
            return "Permission"
        case .compatibility:
            return "Compatibility"
        case .protocolError:
            return "Protocol"
        case .unknown:
            return "Unknown"
        }
    }
}

struct AppServerDiagnostics: Equatable {
    var connectionState: String = "disconnected"
    var cliVersion: String = ""
    var authStatus: String = "unknown"
    var planType: String?
    var currentModel: String = ""
    var reconnectAttemptCount: Int = 0
    var lastPingLatencyMS: Double?
    var lastSuccessfulPingAt: Date?
    var lastRPCErrorMessage: String?
    var lastRPCErrorAt: Date?
    var lastCheckedAt: Date?
    var minimumRequiredVersion: String = "0.106.0"
}

struct AppServerRateLimitSummary: Equatable, Identifiable {
    let name: String
    let usedPercent: Double?
    let remainingPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Date?

    var id: String { "\(self.name)-\(self.windowMinutes ?? -1)" }
}

struct AppServerTokenUsageBreakdown: Equatable {
    let totalTokens: Int?
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let cacheWriteInputTokens: Int?
    let outputTokens: Int?
    let reasoningOutputTokens: Int?
}

struct AppServerContextUsageSummary: Equatable {
    let usedTokens: Int?
    let maxTokens: Int?
    let remainingTokens: Int?
    let updatedAt: Date
    let lastUsage: AppServerTokenUsageBreakdown?
    let totalUsage: AppServerTokenUsageBreakdown?

    init(usedTokens: Int?, maxTokens: Int?, remainingTokens: Int?, updatedAt: Date,
         lastUsage: AppServerTokenUsageBreakdown? = nil, totalUsage: AppServerTokenUsageBreakdown? = nil) {
        self.usedTokens = usedTokens
        self.maxTokens = maxTokens
        self.remainingTokens = remainingTokens
        self.updatedAt = updatedAt
        self.lastUsage = lastUsage
        self.totalUsage = totalUsage
    }

    var remainingPercent: Double? {
        if let remainingTokens, let maxTokens, maxTokens > 0 {
            return max(0, min(100, (Double(remainingTokens) / Double(maxTokens)) * 100))
        }
        if let usedTokens, let maxTokens, maxTokens > 0 {
            return max(0, min(100, ((Double(maxTokens) - Double(usedTokens)) / Double(maxTokens)) * 100))
        }
        return nil
    }
}

struct AppServerResolvedPendingRequest: Equatable, Identifiable {
    let threadID: String
    let requestIDKey: String
    let resolvedAt: Date

    var id: String { "\(self.threadID):\(self.requestIDKey):\(self.resolvedAt.timeIntervalSince1970)" }
}
