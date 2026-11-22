import Foundation

enum AppServerPermissionGrantScope: String, CaseIterable, Identifiable {
    case turn
    case session

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .turn: return L10n.text("This turn")
        case .session: return L10n.text("This session")
        }
    }
}

enum AppServerOfficialRequestError: LocalizedError {
    case unsupportedPermissions
    case invalidDecision
    case invalidAnswer
    case requestResolved

    var errorDescription: String? {
        switch self {
        case .unsupportedPermissions:
            return L10n.text("This permission request contains access the app cannot display. Deny it or review it in another Codex client.")
        case .invalidDecision:
            return L10n.text("This decision is not available for the current request.")
        case .invalidAnswer:
            return L10n.text("Answer every question using an available option or its allowed free-form field.")
        case .requestResolved:
            return L10n.text("This request has already been resolved.")
        }
    }
}

struct AppServerPermissionApproval: Equatable {
    let cwd: String?
    let reason: String?
    let profile: JSONValue
    let summaryLines: [String]
    let unsupportedReason: String?

    var canGrant: Bool { self.unsupportedReason == nil }

    init(profile: JSONValue, cwd: String?, reason: String?) {
        self.cwd = cwd
        self.reason = reason
        do {
            let validated = try PermissionProfileValidator.validate(profile)
            self.profile = validated.profile
            self.summaryLines = validated.lines
            self.unsupportedReason = nil
        } catch {
            self.profile = .object([:])
            self.summaryLines = []
            self.unsupportedReason = AppServerOfficialRequestError.unsupportedPermissions.errorDescription
        }
    }

    func response(grant: Bool, scope: AppServerPermissionGrantScope = .turn) throws -> JSONValue {
        guard !grant || self.canGrant else {
            throw AppServerOfficialRequestError.unsupportedPermissions
        }
        return .object([
            "permissions": grant ? self.profile : .object([:]),
            "scope": .string(grant ? scope.rawValue : AppServerPermissionGrantScope.turn.rawValue),
        ])
    }
}

private enum PermissionProfileValidator {
    static func validate(_ value: JSONValue) throws -> (profile: JSONValue, lines: [String]) {
        let object = try self.object(value, keys: ["network", "fileSystem"])
        var granted: [String: JSONValue] = [:]
        var lines: [String] = []

        if let network = object["network"], network != .null {
            let fields = try self.object(network, keys: ["enabled"])
            if let enabled = fields["enabled"], enabled != .null {
                guard case .bool(let allowed) = enabled else { throw self.unsupported }
                lines.append(allowed ? L10n.text("Network: enabled") : L10n.text("Network: disabled"))
            }
            granted["network"] = network
        }

        if let fileSystem = object["fileSystem"], fileSystem != .null {
            let fields = try self.object(fileSystem, keys: ["read", "write", "entries", "globScanMaxDepth"])
            let read = try self.paths(fields["read"])
            let write = try self.paths(fields["write"])

            if let entries = fields["entries"], entries != .null {
                guard case .array(let values) = entries else { throw self.unsupported }
                for value in values {
                    let entry = try self.object(value, keys: ["path", "access"])
                    guard case .string(let access)? = entry["access"],
                          ["read", "write", "deny"].contains(access),
                          let path = entry["path"] else { throw self.unsupported }
                    let label = try self.pathLabel(path)
                    let accessLabel: String
                    switch access {
                    case "read": accessLabel = L10n.text("Read")
                    case "write": accessLabel = L10n.text("Write")
                    default: accessLabel = L10n.text("Deny")
                    }
                    lines.append("\(accessLabel): \(label)")
                }
            } else {
                lines.append(contentsOf: read.map { L10n.format("Read: %@", $0) })
                lines.append(contentsOf: write.map { L10n.format("Write: %@", $0) })
            }

            if let depth = fields["globScanMaxDepth"], depth != .null {
                guard case .number(let number) = depth,
                      number.isFinite, number > 0, number.rounded(.down) == number else {
                    throw self.unsupported
                }
                lines.append(L10n.format("Glob scan depth: %@", String(format: "%.0f", number)))
            }
            granted["fileSystem"] = fileSystem
        }
        if lines.isEmpty {
            lines.append(L10n.text("No additional network or file access is enabled."))
        }
        return (.object(granted), lines)
    }

    private static var unsupported: AppServerOfficialRequestError { .unsupportedPermissions }

    private static func object(_ value: JSONValue, keys: Set<String>) throws -> [String: JSONValue] {
        guard case .object(let object) = value, Set(object.keys).isSubset(of: keys) else {
            throw self.unsupported
        }
        return object
    }

    private static func text(_ value: JSONValue?) throws -> String {
        guard case .string(let text)? = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw self.unsupported
        }
        return text
    }

    private static func paths(_ value: JSONValue?) throws -> [String] {
        guard let value, value != .null else { return [] }
        guard case .array(let values) = value else { throw self.unsupported }
        return try values.map { try self.text($0) }
    }

    private static func pathLabel(_ value: JSONValue) throws -> String {
        guard case .object(let fields) = value,
              case .string(let type)? = fields["type"] else { throw self.unsupported }
        switch type {
        case "path":
            _ = try self.object(value, keys: ["type", "path"])
            return try self.text(fields["path"])
        case "glob_pattern":
            _ = try self.object(value, keys: ["type", "pattern"])
            return L10n.format("Pattern %@", try self.text(fields["pattern"]))
        case "special":
            _ = try self.object(value, keys: ["type", "value"])
            guard let special = fields["value"] else { throw self.unsupported }
            let target = try self.object(special, keys: ["kind", "subpath"])
            guard case .string(let kind)? = target["kind"] else { throw self.unsupported }
            let label: String
            switch kind {
            case "root": label = L10n.text("Entire filesystem")
            case "minimal": label = L10n.text("Platform minimum access")
            case "project_roots", "current_working_directory": label = L10n.text("Project roots")
            case "tmpdir": label = L10n.text("Temporary directory")
            case "slash_tmp": label = "/tmp"
            default: throw self.unsupported
            }
            if let subpath = target["subpath"], subpath != .null {
                guard kind == "project_roots" || kind == "current_working_directory" else {
                    throw self.unsupported
                }
                return "\(label): \(try self.text(subpath))"
            }
            return label
        default:
            throw self.unsupported
        }
    }
}

