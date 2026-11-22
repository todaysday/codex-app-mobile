import Foundation

struct CodexHistoryPreview: Equatable {
    static let maximumCharacters = 32_000
    let text: String
    let isTruncated: Bool

    init(_ text: String, limit: Int = maximumCharacters) {
        let prefix = text.prefix(max(0, limit) + 1)
        self.isTruncated = prefix.count > max(0, limit)
        self.text = String(prefix.prefix(max(0, limit)))
    }

    static func json(_ value: JSONValue) -> CodexHistoryPreview {
        if case .string(let text) = value { return .init(text) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "Unavailable"
        return .init(text)
    }
}

struct CodexHistoryField: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let value: String
}

struct CodexHistorySection: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let content: CodexHistoryPreview
}

struct CodexHistoryFileChange: Identifiable, Equatable {
    let id: Int
    let path: String
    let kind: String
    let destination: String?
    let diff: CodexHistoryPreview
}

struct CodexAgentHistoryItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user, assistant, plan, reasoning, command, fileChange, tool, agentAction, event
    }

    struct ID: Hashable {
        let turnID: String
        let itemID: String
        let occurrence: Int
    }

    let id: ID
    let kind: Kind
    let title: String
    let status: String?
    let body: CodexHistoryPreview?
    let fields: [CodexHistoryField]
    let sections: [CodexHistorySection]
    let files: [CodexHistoryFileChange]
    let destinations: [String]

    static func items(in turn: CodexTurn) -> [CodexAgentHistoryItem] {
        let payloads = turn.rawItems.isEmpty ? turn.items.map(legacyPayload) : turn.rawItems
        var occurrences: [String: Int] = [:]
        return payloads.enumerated().map { index, value in
            let itemID = value["id"]?.stringValue ?? "item-\(index)"
            let occurrence = occurrences[itemID, default: 0]
            occurrences[itemID] = occurrence + 1
            return .init(id: .init(turnID: turn.id, itemID: itemID, occurrence: occurrence), payload: value)
        }
    }

    private init(id: ID, payload: JSONValue) {
        self.id = id
        let type = payload["type"]?.stringValue ?? "Unknown item"
        self.status = payload["status"]?.stringValue
        var kind: Kind = .event
        var title = type
        var body: String?
        var fields: [CodexHistoryField] = []
        var sections: [CodexHistorySection] = []
        var files: [CodexHistoryFileChange] = []
        var destinations: [String] = []

        func addField(_ label: String, _ key: String) {
            guard let value = payload[key]?.stringValue, !value.isEmpty else { return }
            fields.append(.init(label: label, value: value))
        }
        func addSection(_ title: String, _ key: String) {
            guard let value = payload[key], value != .null else { return }
            sections.append(.init(title: title, content: .json(value)))
        }

        switch type {
        case "userMessage":
            kind = .user
            title = "You"
            body = (payload["content"]?.arrayValue ?? []).compactMap { input in
                switch input["type"]?.stringValue {
                case "text": return input["text"]?.stringValue
                case "image": return "Image attachment"
                case "localImage": return "Image: \(input["path"]?.stringValue ?? "attachment")"
                case "skill", "mention": return input["name"]?.stringValue ?? input["path"]?.stringValue
                default: return "Attachment: \(input["type"]?.stringValue ?? "unknown")"
                }
            }.joined(separator: "\n\n")
        case "agentMessage":
            kind = .assistant
            title = "Agent"
            body = payload["text"]?.stringValue
            addField("Phase", "phase")
        case "plan":
            kind = .plan
            title = "Plan"
            body = payload["text"]?.stringValue
        case "reasoning":
            kind = .reasoning
            title = "Reasoning summary"
            body = (payload["summary"]?.arrayValue ?? []).compactMap {
                $0["text"]?.stringValue ?? $0.stringValue
            }.joined(separator: "\n\n")
        case "commandExecution":
            kind = .command
            title = "Command"
            body = payload["command"]?.stringValue
            addField("Directory", "cwd")
            if let code = payload["exitCode"]?.intValue { fields.append(.init(label: "Exit code", value: String(code))) }
            if let duration = payload["durationMs"]?.intValue { fields.append(.init(label: "Duration", value: "\(duration) ms")) }
            addSection("Output", "aggregatedOutput")
            if let actions = payload["commandActions"]?.arrayValue, !actions.isEmpty {
                addSection("Actions", "commandActions")
            }
        case "fileChange":
            kind = .fileChange
            title = "File changes"
            files = (payload["changes"]?.arrayValue ?? []).enumerated().map { index, change in
                let kindValue = change["kind"]
                return .init(id: index, path: change["path"]?.stringValue ?? "Unknown path",
                             kind: kindValue?["type"]?.stringValue ?? kindValue?.stringValue ?? "change",
                             destination: kindValue?["movePath"]?.stringValue,
                             diff: .init(change["diff"]?.stringValue ?? "No diff was returned."))
            }
            if files.isEmpty { body = "No file details were returned." }
        case "mcpToolCall", "dynamicToolCall":
            kind = .tool
            title = payload["tool"]?.stringValue ?? "Tool call"
            addField("Server", "server")
            addField("Namespace", "namespace")
            if let duration = payload["durationMs"]?.intValue { fields.append(.init(label: "Duration", value: "\(duration) ms")) }
            if let success = payload["success"]?.boolValue { fields.append(.init(label: "Succeeded", value: success ? "Yes" : "No")) }
            addSection("Arguments", "arguments")
            addSection("Result", "result")
            addSection("Output", "contentItems")
            addSection("Error", "error")
        case "functionCallOutput":
            kind = .tool
            title = payload["name"]?.stringValue ?? "Tool output"
            addField("Namespace", "namespace")
            addSection("Output", "output")
        case "collabAgentToolCall":
            kind = .agentAction
            title = payload["tool"]?.stringValue ?? "Agent action"
            body = payload["prompt"]?.stringValue
            addField("Sender", "senderThreadId")
            addField("Model", "model")
            addField("Reasoning", "reasoningEffort")
            addSection("Agent states", "agentsStates")
            destinations = (payload["receiverThreadIds"]?.arrayValue ?? []).compactMap(\.stringValue)
        case "subAgentActivity":
            kind = .agentAction
            title = "Agent activity"
            addField("Activity", "kind")
            addField("Agent", "agentPath")
            addField("Model", "model")
            addField("Reasoning", "reasoningEffort")
            destinations = payload["agentThreadId"]?.stringValue.map { [$0] } ?? []
        case "webSearch":
            title = "Web search"
            body = payload["query"]?.stringValue
            addSection("Action", "action")
        case "enteredReviewMode", "exitedReviewMode":
            title = type == "enteredReviewMode" ? "Review started" : "Review completed"
            body = payload["review"]?.stringValue
        case "contextCompaction":
            title = "Context compacted"
        case "imageView":
            title = "Image inspected"
            addField("Path", "path")
        case "imageGeneration", "sleep", "hookPrompt":
            title = ["imageGeneration": "Image generation", "sleep": "Waiting", "hookPrompt": "Hook prompt"][type] ?? type
            sections.append(.init(title: "Details", content: .json(payload)))
        default:
            sections.append(.init(title: "Details", content: .json(payload)))
        }

        self.kind = kind
        self.title = title
        self.body = body.flatMap { $0.isEmpty ? nil : .init($0) }
        self.fields = fields
        self.sections = sections
        self.files = files
        var seen = Set<String>()
        self.destinations = destinations.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func legacyPayload(_ item: CodexTurnItem) -> JSONValue {
        var value: [String: JSONValue] = ["id": .string(item.id)]
        switch item {
        case .userMessage(_, let text):
            value["type"] = .string("userMessage")
            value["content"] = .array([.object(["type": .string("text"), "text": .string(text)])])
        case .agentMessage(_, let text): value["type"] = .string("agentMessage"); value["text"] = .string(text)
        case .plan(_, let text): value["type"] = .string("plan"); value["text"] = .string(text)
        case .reasoning(_, let text): value["type"] = .string("reasoning"); value["summary"] = .array([.string(text)])
        case .commandExecution(_, let command, let status, let output):
            value["type"] = .string("commandExecution")
            value["command"] = .string(command)
            value["status"] = .string(status)
            value["aggregatedOutput"] = output.map(JSONValue.string) ?? .null
        case .fileChange(_, let status, _): value["type"] = .string("fileChange"); value["status"] = .string(status)
        case .other(_, let type): value["type"] = .string(type)
        }
        return .object(value)
    }
}

struct CodexAgentHistoryTurn: Identifiable, Equatable {
    let id: String
    let status: String
    let model: String?
    let items: [CodexAgentHistoryItem]

    init(_ turn: CodexTurn) {
        self.id = turn.id
        self.status = turn.status
        self.model = turn.model
        self.items = CodexAgentHistoryItem.items(in: turn)
    }
}
