import Foundation

/// Wire contracts verified against official Codex rust-v0.171.0; see docs/OFFICIAL_CODEX_REVIEW.md.
struct CodexThreadGoal: Decodable, Equatable {
    let threadID: String
    let objective: String
    let status: String
    let tokenBudget: Int?
    let tokensUsed: Int
    let timeUsedSeconds: Int
    let createdAt: Int
    let updatedAt: Int

    static let editableStatuses = ["active", "paused", "blocked", "usageLimited", "budgetLimited", "complete"]

    var statusTitle: String {
        switch status {
        case "usageLimited": "Usage limited"
        case "budgetLimited": "Budget limited"
        default: status.prefix(1).uppercased() + status.dropFirst()
        }
    }

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case objective, status, tokenBudget, tokensUsed, timeUsedSeconds, createdAt, updatedAt
    }
}

enum CodexGoalBudgetChange: Equatable {
    case unchanged
    case unlimited
    case limit(Int)
}

struct CodexPlanStep: Decodable, Equatable {
    let step: String
    let status: String
}

struct CodexThreadPlan: Decodable, Equatable {
    let threadID: String
    let turnID: String
    let explanation: String?
    let steps: [CodexPlanStep]

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case explanation
        case steps = "plan"
    }
}

struct CodexThreadDiff: Decodable, Equatable {
    let threadID: String
    let turnID: String
    let diff: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
        case diff
    }
}

enum CodexOfficialError: LocalizedError {
    case unsupported(String)
    case invalidInput(String)
    case readOnlyThread
    case threadBusy
    case historyUnavailable
    case connectionChanged

    var errorDescription: String? {
        switch self {
        case .unsupported(let method):
            switch method {
            case "thread/goal/get", "thread/goal/set", "thread/goal/clear":
                "This goal operation is unavailable on the connected server."
            case "thread/list.relationships":
                "Subagent navigation is unavailable on the connected server."
            case "thread/name/set":
                "Thread renaming is unavailable on the connected server."
            case "thread/compact/start":
                "Manual compaction is unavailable on the connected server."
            case "thread/revert", "thread/turns/list":
                "This conversation history operation is unavailable on the connected server."
            default:
                "This feature is unavailable on the connected server."
            }
        case .invalidInput(let message): message
        case .readOnlyThread: "This thread does not accept direct input. You can still read its messages."
        case .threadBusy: "Wait for this thread to become idle before changing its conversation history."
        case .historyUnavailable: "Revert requires a loaded, persistent thread with paginated history."
        case .connectionChanged: "The server connection changed. Refresh this thread and try again."
        }
    }
}

enum CodexOfficialParameters {
    static func goalSet(threadID: String, objective: String?, status: String?, budget: CodexGoalBudgetChange) throws -> JSONValue {
        guard !threadID.isEmpty else { throw CodexOfficialError.invalidInput("Select a thread first.") }
        var values: [String: JSONValue] = ["threadId": .string(threadID), "origin": .string("user")]
        if let objective {
            let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw CodexOfficialError.invalidInput("Enter a goal objective.") }
            values["objective"] = .string(trimmed)
        }
        if let status {
            guard CodexThreadGoal.editableStatuses.contains(status) else {
                throw CodexOfficialError.invalidInput("Choose a supported goal status.")
            }
            values["status"] = .string(status)
        }
        switch budget {
        case .unchanged: break
        case .unlimited: values["tokenBudget"] = .null
        case .limit(let amount):
            guard amount >= 0, amount <= 9_007_199_254_740_991 else {
                throw CodexOfficialError.invalidInput("Enter a nonnegative whole-number token budget.")
            }
            values["tokenBudget"] = .number(Double(amount))
        }
        guard values.count > 2 else { throw CodexOfficialError.invalidInput("Choose a goal change to save.") }
        return .object(values)
    }
}

struct CodexAgentTreeRow: Identifiable, Equatable {
    let thread: RemoteThreadRecord
    let depth: Int
    let hasMissingParent: Bool
    var id: String { thread.id }
}

enum CodexAgentTree {
    static let sourceKinds = ["subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther"]

    static func rows(rootID: String, threads: [RemoteThreadRecord]) -> [CodexAgentTreeRow] {
        var records: [String: RemoteThreadRecord] = [:]
        for thread in threads where thread.id != rootID {
            guard let parent = thread.parentThreadID, !parent.isEmpty else { continue }
            if let previous = records[thread.id], previous.updatedAt > thread.updatedAt { continue }
            records[thread.id] = thread
        }
        let ordered = records.values.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
        let children = Dictionary(grouping: ordered, by: { $0.parentThreadID ?? "" })
        var visited: Set<String> = [rootID]
        var rows: [CodexAgentTreeRow] = []

        // An iterative traversal also handles very deep or cyclic server metadata safely.
        func appendBranch(_ initial: RemoteThreadRecord, missingParent: Bool) {
            var pending: [(RemoteThreadRecord, Int, Bool)] = [(initial, 0, missingParent)]
            while let (thread, depth, missing) = pending.popLast() {
                guard visited.insert(thread.id).inserted else { continue }
                rows.append(.init(thread: thread, depth: depth, hasMissingParent: missing))
                for child in (children[thread.id] ?? []).reversed() {
                    pending.append((child, depth + 1, false))
                }
            }
        }
        for child in children[rootID] ?? [] { appendBranch(child, missingParent: false) }
        // Preserve inspectability if a parent is absent or inconsistent; do not invent it.
        for thread in ordered where !visited.contains(thread.id) {
            appendBranch(thread, missingParent: true)
        }
        return rows
    }
}
