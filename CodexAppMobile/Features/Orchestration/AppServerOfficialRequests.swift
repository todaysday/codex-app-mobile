import Foundation

extension AppServerClient {
    static func parseOfficialRequest(
        id: JSONValue,
        method: String,
        params: [String: JSONValue]
    ) -> AppServerPendingRequest? {
        let normalized = method.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard [
            "item/permissions/requestapproval",
            "item/commandexecution/requestapproval",
            "item/tool/requestuserinput",
            "tool/requestuserinput",
        ].contains(normalized),
        let requestKey = AppServerMessageRouter.idKey(from: id) else { return nil }

        func request(
            _ kind: AppServerPendingRequestKind,
            commandKind: String = "command",
            isBlocking: Bool = true,
            additionalPermissionProfile: AppServerPermissionApproval? = nil
        ) -> AppServerPendingRequest {
            AppServerPendingRequest(
                requestIDKey: requestKey,
                rpcID: id,
                method: method,
                threadID: params["threadId"]?.stringValue ?? params["thread_id"]?.stringValue ?? "",
                turnID: params["turnId"]?.stringValue ?? params["turn_id"]?.stringValue ?? "",
                itemID: params["itemId"]?.stringValue ?? params["item_id"]?.stringValue ?? "",
                kind: kind,
                commandKind: commandKind,
                isBlocking: isBlocking,
                additionalPermissionProfile: additionalPermissionProfile
            )
        }

        switch normalized {
        case "item/permissions/requestapproval":
            return request(.permissionsApproval(AppServerPermissionApproval(
                profile: params["permissions"] ?? .null,
                cwd: params["cwd"]?.stringValue,
                reason: params["reason"]?.stringValue
            )))

        case "item/commandexecution/requestapproval":
            let commandKind = params["kind"]?.stringValue ?? "command"
            guard ["command", "writeStdin", "humanCommand"].contains(commandKind) else {
                return request(.unknown, commandKind: commandKind)
            }
            let execPolicy = Self.parseExecPolicyAmendment(
                params["proposedExecpolicyAmendment"] ?? params["proposed_execpolicy_amendment"]
            )
            let networkPolicies = Self.parseProposedNetworkPolicyAmendments(
                params["proposedNetworkPolicyAmendments"] ?? params["proposed_network_policy_amendments"]
            )
            let networkContext = Self.parseNetworkApprovalContext(
                params["networkApprovalContext"] ?? params["network_approval_context"]
            )
            let rawAdditionalPermissions = params["additionalPermissions"] ?? params["additional_permissions"]
            let additionalPermissionProfile: AppServerPermissionApproval?
            if let rawAdditionalPermissions, rawAdditionalPermissions != .null {
                additionalPermissionProfile = AppServerPermissionApproval(
                    profile: rawAdditionalPermissions,
                    cwd: params["cwd"]?.stringValue,
                    reason: nil
                )
            } else {
                additionalPermissionProfile = nil
            }
            let rawDecisions = params["availableDecisions"] ?? params["available_decisions"]
            var decisions: [AppServerCommandApprovalDecisionOption]
            if let rawDecisions, rawDecisions != .null {
                guard let values = rawDecisions.arrayValue, !values.isEmpty else {
                    return request(.unknown, commandKind: commandKind)
                }
                decisions = Self.parseAvailableCommandApprovalDecisions(
                    values,
                    proposedExecPolicyAmendment: execPolicy,
                    proposedNetworkPolicyAmendments: networkPolicies
                )
            } else {
                decisions = [.accept, .acceptForSession]
                if let execPolicy {
                    decisions.append(.acceptWithExecpolicyAmendment(amendment: execPolicy))
                }
                if let networkPolicy = networkPolicies.first {
                    decisions.append(.applyNetworkPolicyAmendment(amendment: networkPolicy))
                } else if networkContext != nil {
                    decisions.append(.applyNetworkPolicyAmendment(amendment: nil))
                }
                decisions.append(contentsOf: [.decline, .cancel])
            }
            if commandKind == "humanCommand" {
                decisions = decisions.filter {
                    switch $0 {
                    case .accept, .decline, .cancel: return true
                    default: return false
                    }
                }
            }
            if additionalPermissionProfile?.canGrant == false {
                decisions = decisions.filter {
                    switch $0 {
                    case .decline, .cancel: return true
                    default: return false
                    }
                }
            }
            guard !decisions.isEmpty else { return request(.unknown, commandKind: commandKind) }
            return request(.commandApproval(
                command: params["command"]?.stringValue ?? "",
                cwd: params["cwd"]?.stringValue,
                reason: params["reason"]?.stringValue,
                availableDecisions: decisions,
                proposedExecPolicyAmendment: commandKind == "humanCommand" ? nil : execPolicy,
                proposedNetworkPolicyAmendments: commandKind == "humanCommand" ? [] : networkPolicies,
                networkApprovalContext: networkContext,
                additionalPermissions: Self.parseAdditionalPermissions(rawAdditionalPermissions)
            ), commandKind: commandKind, additionalPermissionProfile: additionalPermissionProfile)

        default:
            guard let rows = params["questions"]?.arrayValue, !rows.isEmpty else {
                return request(.unknown)
            }
            var seen: Set<String> = []
            var questions: [AppServerUserInputQuestion] = []
            for row in rows {
                guard let fields = row.objectValue,
                      let questionID = fields["id"]?.stringValue
                        ?? fields["questionId"]?.stringValue
                        ?? fields["name"]?.stringValue
                        ?? fields["key"]?.stringValue,
                      !questionID.isEmpty, seen.insert(questionID).inserted,
                      let prompt = fields["question"]?.stringValue
                        ?? fields["prompt"]?.stringValue
                        ?? fields["header"]?.stringValue
                        ?? fields["title"]?.stringValue else { return request(.unknown) }

                let rawOptions = fields["options"] ?? fields["choices"] ?? fields["answers"]
                var options: [AppServerUserInputQuestionOption] = []
                if let rawOptions, rawOptions != .null {
                    guard let values = rawOptions.arrayValue else { return request(.unknown) }
                    for value in values {
                        guard let option = value.objectValue,
                              let label = option["label"]?.stringValue
                                ?? option["title"]?.stringValue
                                ?? option["value"]?.stringValue
                                ?? option["id"]?.stringValue else { return request(.unknown) }
                        options.append(AppServerUserInputQuestionOption(
                            label: label,
                            description: option["description"]?.stringValue
                                ?? option["helpText"]?.stringValue
                                ?? option["details"]?.stringValue ?? ""
                        ))
                    }
                }
                for flag in ["isSecret", "isOther"] {
                    if let value = fields[flag], value != .null, value.boolValue == nil {
                        return request(.unknown)
                    }
                }
                questions.append(AppServerUserInputQuestion(
                    id: questionID,
                    prompt: prompt,
                    options: options,
                    header: fields["header"]?.stringValue,
                    isSecret: fields["isSecret"]?.boolValue ?? false,
                    isOther: fields["isOther"]?.boolValue ?? false
                ))
            }
            return request(.userInput(questions: questions), isBlocking: params["isBlocking"]?.boolValue ?? true)
        }
    }

    static func validateOfficialCommandDecision(
        request: AppServerPendingRequest,
        decision: AppServerCommandApprovalDecisionResponse
    ) throws {
        guard case .commandApproval(
            _, _, _, let options, let execPolicy, let networkPolicies, let networkContext, _
        ) = request.kind else { throw AppServerOfficialRequestError.invalidDecision }

        if request.additionalPermissionProfile?.canGrant == false {
            switch decision {
            case .decline, .cancel: break
            default: throw AppServerOfficialRequestError.unsupportedPermissions
            }
        }

        if request.commandKind == "humanCommand" {
            switch decision {
            case .accept, .decline, .cancel: break
            default: throw AppServerOfficialRequestError.invalidDecision
            }
        }
        let permitted = options.contains { option in
            switch (option, decision) {
            case (.accept, .accept), (.acceptForSession, .acceptForSession),
                 (.decline, .decline), (.cancel, .cancel):
                return true
            case (.acceptWithExecpolicyAmendment(let expected), .acceptWithExecpolicyAmendment(let actual)):
                return (expected ?? execPolicy) == actual
            case (.applyNetworkPolicyAmendment(let expected), .applyNetworkPolicyAmendment(let actual)):
                if let expected { return expected == actual }
                return networkPolicies.contains(actual) || networkContext?.host == actual.host
            default:
                return false
            }
        }
        guard permitted else { throw AppServerOfficialRequestError.invalidDecision }
    }

    static func makeOfficialUserInputAnswers(
        questions: [AppServerUserInputQuestion],
        values: [String: String]
    ) throws -> [String: [String]] {
        var answers: [String: [String]] = [:]
        for question in questions {
            answers[question.id] = [values[question.id] ?? ""]
        }
        try Self.validateAnswers(questions: questions, answers: answers)
        return answers
    }

    static func validateOfficialUserInput(
        request: AppServerPendingRequest,
        answers: [String: [String]]
    ) throws {
        guard case .userInput(let questions) = request.kind else {
            throw AppServerOfficialRequestError.invalidAnswer
        }
        try Self.validateAnswers(questions: questions, answers: answers)
    }

    private static func validateAnswers(
        questions: [AppServerUserInputQuestion],
        answers: [String: [String]]
    ) throws {
        guard !questions.isEmpty, Set(answers.keys) == Set(questions.map(\.id)) else {
            throw AppServerOfficialRequestError.invalidAnswer
        }
        for question in questions {
            guard let values = answers[question.id], !values.isEmpty else {
                throw AppServerOfficialRequestError.invalidAnswer
            }
            let choices = Set(question.options.map(\.label))
            for value in values {
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      choices.isEmpty || question.isOther || choices.contains(value) else {
                    throw AppServerOfficialRequestError.invalidAnswer
                }
            }
        }
    }

    func respondPermissionsApproval(
        request: AppServerPendingRequest,
        grant: Bool,
        scope: AppServerPermissionGrantScope = .turn
    ) async throws {
        guard case .permissionsApproval(let approval) = request.kind else {
            throw AppServerOfficialRequestError.invalidDecision
        }
        try await self.respond(to: request, result: approval.response(grant: grant, scope: scope))
    }
}

