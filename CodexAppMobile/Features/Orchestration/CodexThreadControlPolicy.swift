import Foundation

enum CodexGoalBudgetMode: String, CaseIterable, Identifiable {
    case unchanged = "Keep current budget"
    case unlimited = "No token limit"
    case limited = "Set a token limit"

    var id: String { rawValue }
}

enum CodexThreadControlPolicy {
    static func acceptsDirectInput(_ reported: Bool?) -> Bool { reported != false }

    static func budgetChange(mode: CodexGoalBudgetMode, text: String) -> CodexGoalBudgetChange? {
        switch mode {
        case .unchanged: return .unchanged
        case .unlimited: return .unlimited
        case .limited:
            guard let amount = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  amount >= 0, amount <= 9_007_199_254_740_991 else { return nil }
            return .limit(amount)
        }
    }

    static func canCompact(record: RemoteThreadRecord?, activeTurnID: String?, isCompacting: Bool) -> Bool {
        guard let record else { return false }
        return record.status?.type == "idle" && activeTurnID == nil && !isCompacting
            && acceptsDirectInput(record.canAcceptDirectInput)
    }

    static func canRevert(record: RemoteThreadRecord?, activeTurnID: String?, isCompacting: Bool) -> Bool {
        guard let record, !record.ephemeral, record.historyMode == "paginated" else { return false }
        return canCompact(record: record, activeTurnID: activeTurnID, isCompacting: isCompacting)
    }

    static func title(for record: RemoteThreadRecord) -> String {
        for value in [record.agentNickname, record.name, record.preview] {
            if let title = value?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        }
        return "Thread \(record.id.prefix(8))"
    }

    static func statusTitle(_ status: AppServerThreadStatus?) -> String {
        guard let status else { return "Status unavailable" }
        let title: String
        switch status.type {
        case "notLoaded": title = "Not loaded"
        case "idle": title = "Idle"
        case "active": title = "Active"
        case "systemError": title = "System error"
        default: title = status.type.isEmpty ? "Status unavailable" : status.type
        }
        let flags = (status.activeFlags ?? []).map { flag in
            switch flag {
            case "waitingOnApproval": return "Waiting for approval"
            case "waitingOnUserInput", "waitingOnInput": return "Waiting for input"
            default: return flag
            }
        }
        return ([title] + flags).joined(separator: " · ")
    }

    static func turnTitle(_ turn: CodexTurn) -> String {
        for item in turn.items {
            if case .userMessage(_, let text) = item {
                let preview = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty { return String(preview.prefix(90)) }
            }
        }
        return "Turn \(turn.id.prefix(12))"
    }
}
