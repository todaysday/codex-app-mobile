import SwiftUI

struct PendingRequestSheet: View {
    private struct CommandDecisionRow: Identifiable {
        let id: String
        let title: String
        let decision: AppServerCommandApprovalDecisionResponse?
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let request: AppServerPendingRequest

    @State private var freeFormAnswers: [String: String] = [:]
    @State private var otherAnswerQuestionIDs: Set<String> = []
    @State private var permissionScope: AppServerPermissionGrantScope = .turn
    @State private var isSubmitting = false
    @State private var submitError = ""

    init(request: AppServerPendingRequest) {
        self.request = request
    }

    private var isRequestPending: Bool {
        self.appState.appServerClient.pendingRequests.contains {
            $0.instanceID == self.request.instanceID
                && $0.requestIDKey == self.request.requestIDKey
                && $0.rpcID == self.request.rpcID
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("Method")) {
                    Text(self.request.method)
                        .font(.footnote)
                        .textSelection(.enabled)
                    if !self.request.threadID.isEmpty {
                        Text(L10n.format("thread: %@", self.request.threadID))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !self.request.turnID.isEmpty {
                        Text(L10n.format("turn: %@", self.request.turnID))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if case .userInput = self.request.kind {
                    Section {
                        Text(self.request.isBlocking
                            ? L10n.text("Codex is waiting for your answer.")
                            : L10n.text("You can answer while Codex continues working."))
                            .font(.footnote)
                    }
                } else if self.request.commandKind == "humanCommand" {
                    Section {
                        Text(L10n.text("This action needs a fresh decision for this request."))
                            .font(.footnote)
                    }
                }

                switch self.request.kind {
                case .commandApproval(
                    let command,
                    let cwd,
                    let reason,
                    let availableDecisions,
                    let proposedExecPolicyAmendment,
                    let proposedNetworkPolicyAmendments,
                    let networkApprovalContext,
                    let additionalPermissions
                ):
                    Section(self.request.commandKind == "writeStdin"
                        ? L10n.text("Terminal Input")
                        : L10n.text("Command")) {
                        Text(command.isEmpty ? L10n.text("(empty command)") : command)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)

                        if let cwd,
                           !cwd.isEmpty {
                            Text(L10n.format("cwd: %@", cwd))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let reason,
                           !reason.isEmpty {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let profile = self.request.additionalPermissionProfile {
                        self.permissionDetails(for: profile)
                    } else if let additionalPermissions {
                        Section(L10n.text("Requested Access")) {
                            if let network = additionalPermissions.network {
                                let networkRequirement = network ? L10n.text("required") : L10n.text("not required")
                                Text(L10n.format("Network: %@", networkRequirement))
                                    .font(.caption)
                            }
                            if let fileSystem = additionalPermissions.fileSystem {
                                let readable = fileSystem.read?.count ?? 0
                                let writable = fileSystem.write?.count ?? 0
                                Text(L10n.format(
                                    "File system: read %@ path(s), write %@ path(s)",
                                    "\(readable)",
                                    "\(writable)"
                                ))
                                    .font(.caption)
                            }
                        }
                    }

                    if let proposedExecPolicyAmendment,
                       !proposedExecPolicyAmendment.command.isEmpty {
                        Section(L10n.text("Exec Policy Proposal")) {
                            Text(proposedExecPolicyAmendment.command.joined(separator: " "))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }

                    if !proposedNetworkPolicyAmendments.isEmpty || networkApprovalContext != nil {
                        Section(L10n.text("Network Policy")) {
                            if let networkApprovalContext {
                                let protocolValue = networkApprovalContext.protocol?.uppercased() ?? "UNKNOWN"
                                Text(L10n.format("Host: %@ (%@)", networkApprovalContext.host, protocolValue))
                                    .font(.caption)
                            }
                            ForEach(proposedNetworkPolicyAmendments.indices, id: \.self) { index in
                                let amendment = proposedNetworkPolicyAmendments[index]
                                Text(L10n.format("%@: %@", amendment.action.rawValue.uppercased(), amendment.host))
                                    .font(.caption)
                            }
                        }
                    }

                    Section(L10n.text("Decision")) {
                        ForEach(self.commandDecisionRows(
                            availableDecisions: availableDecisions,
                            proposedExecPolicyAmendment: proposedExecPolicyAmendment,
                            proposedNetworkPolicyAmendments: proposedNetworkPolicyAmendments,
                            networkApprovalContext: networkApprovalContext
                        )) { row in
                            Button(row.title) {
                                guard let decision = row.decision else { return }
                                self.respondCommand(decision)
                            }
                            .disabled(row.decision == nil)
                        }
                    }

                case .permissionsApproval(let approval):
                    self.permissionDetails(for: approval)
                    Section(L10n.text("Decision")) {
                        if approval.canGrant {
                            Picker(L10n.text("Allow for"), selection: self.$permissionScope) {
                                ForEach(AppServerPermissionGrantScope.allCases) { scope in
                                    Text(scope.title).tag(scope)
                                }
                            }
                            .pickerStyle(.segmented)
                            Button(L10n.text("Allow requested access")) {
                                self.respondPermissions(grant: true)
                            }
                        }
                        Button(L10n.text("Deny additional access"), role: .destructive) {
                            self.respondPermissions(grant: false)
                        }
                    }

                case .fileChange(let reason):
                    Section(L10n.text("File Change")) {
                        if let reason,
                           !reason.isEmpty {
                            Text(reason)
                                .font(.footnote)
                        } else {
                            Text(L10n.text("Codex requests file-change approval."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section(L10n.text("Decision")) {
                        ForEach(AppServerFileApprovalDecision.allCases) { decision in
                            Button(decision.rawValue) {
                                self.respondFileChange(decision)
                            }
                        }
                    }

                case .userInput(let questions):
                    ForEach(questions) { question in
                        Section {
                            Text(question.prompt)
                            if !question.options.isEmpty {
                                ForEach(question.options.indices, id: \.self) { index in
                                    let option = question.options[index]
                                    Button {
                                        self.otherAnswerQuestionIDs.remove(question.id)
                                        self.freeFormAnswers[question.id] = option.label
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(option.label)
                                                if !option.description.isEmpty {
                                                    Text(option.description)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer()
                                            if !self.otherAnswerQuestionIDs.contains(question.id),
                                               self.freeFormAnswers[question.id] == option.label {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                                if question.isOther {
                                    Button {
                                        if self.otherAnswerQuestionIDs.insert(question.id).inserted {
                                            self.freeFormAnswers[question.id] = ""
                                        }
                                    } label: {
                                        HStack {
                                            Text(L10n.text("Other answer"))
                                            Spacer()
                                            if self.otherAnswerQuestionIDs.contains(question.id) {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                            if question.options.isEmpty || self.otherAnswerQuestionIDs.contains(question.id) {
                                self.answerField(for: question)
                            }
                        } header: {
                            Text(question.header?.isEmpty == false
                                ? question.header ?? ""
                                : L10n.text("Question"))
                        }
                    }

                    Section {
                        Button(L10n.text("Submit")) {
                            self.respondUserInput(questions: questions)
                        }
                    }

                case .unknown:
                    Section {
                        Text(L10n.text("This request type is not yet mapped. Reply from desktop fallback if needed."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !self.submitError.isEmpty {
                    Section {
                        Text(self.submitError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(self.isSubmitting || !self.isRequestPending)
            .navigationTitle(self.request.title)
            .onReceive(self.appState.appServerClient.$pendingRequests) { pendingRequests in
                if !pendingRequests.contains(where: { $0.instanceID == self.request.instanceID }) {
                    self.dismiss()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        self.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.text("Close"))
                    .codexActionButtonStyle()
                }
            }
        }
    }

    @ViewBuilder
    private func permissionDetails(for approval: AppServerPermissionApproval) -> some View {
        Section(L10n.text("Requested Access")) {
            if let reason = approval.reason, !reason.isEmpty {
                Text(reason)
            }
            if let cwd = approval.cwd, !cwd.isEmpty {
                Text(L10n.format("Workspace: %@", cwd))
                    .font(.caption)
                    .textSelection(.enabled)
            }
            ForEach(approval.summaryLines.indices, id: \.self) { index in
                Text(approval.summaryLines[index])
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let unsupportedReason = approval.unsupportedReason {
                Text(unsupportedReason)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func answerField(for question: AppServerUserInputQuestion) -> some View {
        let answer = Binding(
            get: { self.freeFormAnswers[question.id] ?? "" },
            set: { self.freeFormAnswers[question.id] = $0 }
        )
        Group {
            if question.isSecret {
                SecureField(L10n.text("Answer"), text: answer)
            } else {
                TextField(L10n.text("Answer"), text: answer, axis: .vertical)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
    }

    private func commandDecisionRows(
        availableDecisions: [AppServerCommandApprovalDecisionOption],
        proposedExecPolicyAmendment: AppServerExecPolicyAmendment?,
        proposedNetworkPolicyAmendments: [AppServerNetworkPolicyAmendment],
        networkApprovalContext: AppServerNetworkApprovalContext?
    ) -> [CommandDecisionRow] {
        let sourceDecisions: [AppServerCommandApprovalDecisionOption]
        if availableDecisions.isEmpty {
            sourceDecisions = [.accept, .acceptForSession, .decline, .cancel]
        } else {
            sourceDecisions = availableDecisions
        }

        var rows: [CommandDecisionRow] = []
        var counter = 0
        func nextID(_ prefix: String) -> String {
            defer { counter += 1 }
            return "\(prefix)-\(counter)"
        }

        for decision in sourceDecisions {
            switch decision {
            case .accept:
                rows.append(CommandDecisionRow(
                    id: nextID("accept"),
                    title: L10n.text("Accept"),
                    decision: .accept
                ))
            case .acceptForSession:
                rows.append(CommandDecisionRow(
                    id: nextID("accept-session"),
                    title: L10n.text("Accept for Session"),
                    decision: .acceptForSession
                ))
            case .decline:
                rows.append(CommandDecisionRow(
                    id: nextID("decline"),
                    title: L10n.text("Decline"),
                    decision: .decline
                ))
            case .cancel:
                rows.append(CommandDecisionRow(
                    id: nextID("cancel"),
                    title: L10n.text("Cancel Turn"),
                    decision: .cancel
                ))
            case .acceptWithExecpolicyAmendment(let amendment):
                if let amendment = amendment ?? proposedExecPolicyAmendment {
                    rows.append(CommandDecisionRow(
                        id: nextID("accept-execpolicy"),
                        title: L10n.text("Accept + Save Exec Policy"),
                        decision: .acceptWithExecpolicyAmendment(amendment: amendment)
                    ))
                } else {
                    rows.append(CommandDecisionRow(
                        id: nextID("accept-execpolicy-missing"),
                        title: L10n.text("Accept + Save Exec Policy (Unavailable)"),
                        decision: nil
                    ))
                }
            case .applyNetworkPolicyAmendment(let amendment):
                if let amendment = amendment ?? proposedNetworkPolicyAmendments.first {
                    rows.append(CommandDecisionRow(
                        id: nextID("network-policy"),
                        title: L10n.format(
                            "Apply Network Policy: %@ %@",
                            amendment.action.rawValue.uppercased(),
                            amendment.host
                        ),
                        decision: .applyNetworkPolicyAmendment(amendment: amendment)
                    ))
                } else if let networkApprovalContext {
                    rows.append(CommandDecisionRow(
                        id: nextID("network-allow"),
                        title: L10n.format("Allow host %@", networkApprovalContext.host),
                        decision: .applyNetworkPolicyAmendment(
                            amendment: AppServerNetworkPolicyAmendment(
                                host: networkApprovalContext.host,
                                action: .allow
                            )
                        )
                    ))
                    rows.append(CommandDecisionRow(
                        id: nextID("network-deny"),
                        title: L10n.format("Deny host %@", networkApprovalContext.host),
                        decision: .applyNetworkPolicyAmendment(
                            amendment: AppServerNetworkPolicyAmendment(
                                host: networkApprovalContext.host,
                                action: .deny
                            )
                        )
                    ))
                } else {
                    rows.append(CommandDecisionRow(
                        id: nextID("network-policy-missing"),
                        title: L10n.text("Apply Network Policy (Unavailable)"),
                        decision: nil
                    ))
                }
            }
        }

        return rows
    }

    private func respondCommand(_ decision: AppServerCommandApprovalDecisionResponse) {
        self.submit {
            try await self.appState.appServerClient.respondCommandApproval(request: self.request, decision: decision)
        }
    }

    private func respondFileChange(_ decision: AppServerFileApprovalDecision) {
        self.submit {
            try await self.appState.appServerClient.respondFileChangeApproval(request: self.request, decision: decision)
        }
    }

    private func respondPermissions(grant: Bool) {
        self.submit {
            try await self.appState.appServerClient.respondPermissionsApproval(
                request: self.request,
                grant: grant,
                scope: self.permissionScope
            )
        }
    }

    private func respondUserInput(questions: [AppServerUserInputQuestion]) {
        self.submitError = ""
        do {
            let answers = try AppServerClient.makeOfficialUserInputAnswers(
                questions: questions,
                values: self.freeFormAnswers
            )
            self.submit(hideServerError: questions.contains(where: \.isSecret)) {
                try await self.appState.appServerClient.respondUserInput(request: self.request, answers: answers)
            }
        } catch {
            self.submitError = self.appState.appServerClient.userFacingMessage(for: error)
        }
    }

    private func submit(
        hideServerError: Bool = false,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !self.isSubmitting, self.isRequestPending else { return }
        self.submitError = ""
        self.isSubmitting = true
        Task { @MainActor in
            defer { self.isSubmitting = false }
            do {
                try await operation()
                self.freeFormAnswers.removeAll()
                self.dismiss()
            } catch {
                self.submitError = hideServerError
                    ? L10n.text("Could not submit the answer. Try again while the request remains open.")
                    : self.appState.appServerClient.userFacingMessage(for: error)
            }
        }
    }
}
