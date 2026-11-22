import SwiftUI

struct CodexGoalEditorView: View {
    @ObservedObject var client: AppServerClient
    let threadID: String
    @Environment(\.dismiss) private var dismiss
    @State private var objective: String
    @State private var budgetMode: CodexGoalBudgetMode = .unchanged
    @State private var budgetText: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(client: AppServerClient, threadID: String, goal: CodexThreadGoal?) {
        self.client = client
        self.threadID = threadID
        _objective = State(initialValue: goal?.objective ?? "")
        _budgetText = State(initialValue: goal?.tokenBudget.map(String.init) ?? "")
    }

    private var budgetChange: CodexGoalBudgetChange? {
        CodexThreadControlPolicy.budgetChange(mode: budgetMode, text: budgetText)
    }

    private var canSave: Bool {
        !isSaving && client.state == .connected && !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && budgetChange != nil && !client.unsupportedOfficialMethods.contains("thread/goal/set")
            && CodexThreadControlPolicy.acceptsDirectInput(client.threadRecordsByID[threadID]?.canAcceptDirectInput)
    }

    var body: some View {
        Form {
            Section("Objective") {
                TextField("What should Codex accomplish?", text: $objective, axis: .vertical)
                    .lineLimit(3...8).disabled(isSaving)
            }
            Section("Token Budget") {
                Picker("Budget", selection: $budgetMode) {
                    ForEach(CodexGoalBudgetMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }.disabled(isSaving)
                if budgetMode == .limited {
                    TextField("Token count", text: $budgetText).keyboardType(.numberPad).disabled(isSaving)
                    if budgetChange == nil {
                        Text("Enter a nonnegative whole-number token budget.").font(.caption).foregroundStyle(.red)
                    }
                }
                Text("Keeping the current budget leaves it unchanged on the server. No token limit explicitly removes the budget.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            if isSaving { ProgressView("Saving goal…") }
        }
        .navigationTitle("Edit Goal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!canSave)
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        guard canSave, let budgetChange else { return }
        isSaving = true
        errorMessage = nil
        let submittedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            defer { isSaving = false }
            do {
                _ = try await client.threadGoalSet(threadID: threadID, objective: submittedObjective, budget: budgetChange)
                dismiss()
            } catch { errorMessage = client.userFacingMessage(for: error) }
        }
    }
}

struct CodexTurnSnapshotView: View {
    enum Kind: Equatable { case plan, diff }
    @ObservedObject var client: AppServerClient
    let threadID: String
    let kind: Kind

    var body: some View {
        Group {
            switch kind {
            case .plan:
                if let plan = client.threadPlansByID[threadID] {
                    List {
                        Section {
                            Text("Turn \(plan.turnID)").font(.caption).textSelection(.enabled)
                            if let explanation = plan.explanation, !explanation.isEmpty { Text(explanation) }
                        }
                        Section("Plan") {
                            ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(step.step, systemImage: stepIcon(step.status))
                                    Text(step.status).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No Plan Reported", systemImage: "list.bullet.clipboard",
                                           description: Text("The server has not sent a plan for this thread during this connection."))
                }
            case .diff:
                if let snapshot = client.threadDiffsByID[threadID] {
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Turn \(snapshot.turnID)").font(.caption).foregroundStyle(.secondary)
                            Text(snapshot.diff.isEmpty ? "No changes in this snapshot." : snapshot.diff)
                                .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        }.padding()
                    }
                } else {
                    ContentUnavailableView("No Server Diff Reported", systemImage: "doc.text.magnifyingglass",
                                           description: Text("Use the Git menu for the current working-tree diff."))
                }
            }
        }
        .navigationTitle(kind == .plan ? "Current Plan" : "Server Changes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stepIcon(_ status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "inProgress": return "clock"
        default: return "circle"
        }
    }
}

struct CodexModelDetailsView: View {
    let model: AppServerModelDescriptor

    var body: some View {
        Form {
            Section("Model") {
                LabeledContent("Name", value: model.displayName)
                LabeledContent("Identifier", value: model.model).textSelection(.enabled)
                if let description = model.description, !description.isEmpty { Text(description) }
                if let reasoning = model.defaultReasoningEffort { LabeledContent("Default reasoning", value: reasoning) }
                if !model.reasoningEffortOptions.isEmpty {
                    LabeledContent("Reasoning options", value: model.reasoningEffortOptions.map(\.value).joined(separator: ", "))
                }
                LabeledContent("Input types", value: model.inputModalities.isEmpty ? "Not reported" : model.inputModalities.joined(separator: ", "))
                if let version = model.multiAgentVersion { LabeledContent("Multi-agent version", value: version) }
            }
            if !model.serviceTiers.isEmpty {
                Section("Server-Reported Service Tiers") {
                    if let tier = model.defaultServiceTier { LabeledContent("Default tier", value: tier) }
                    ForEach(model.serviceTiers) { tier in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tier.name).font(.headline)
                            Text(tier.description).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let message = model.availabilityNuxMessage, !message.isEmpty { Section { Text(message) } }
            if let upgrade = model.upgradeInfo {
                Section("Suggested Upgrade") {
                    Text(upgrade.model)
                    if let copy = upgrade.upgradeCopy { Text(copy).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Model Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CodexThreadUsageView: View {
    @ObservedObject var client: AppServerClient
    let threadID: String

    var body: some View {
        Form {
            if let usage = client.contextUsage(for: threadID) {
                Section("Latest Context") {
                    LabeledContent("Latest tokens", value: count(usage.usedTokens))
                    LabeledContent("Reported window", value: count(usage.maxTokens))
                    if let remaining = usage.remainingPercent {
                        LabeledContent("Approximate remaining", value: "\(Int(remaining.rounded()))%")
                    }
                    Text("The percentage is an estimate from the last reported token count and context window.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let latest = usage.lastUsage { breakdown(latest, title: "Latest Usage Breakdown") }
                if let total = usage.totalUsage { breakdown(total, title: "Cumulative Usage") }
            } else {
                Text("The server has not reported token usage for this thread during this connection.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Token Usage")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func breakdown(_ usage: AppServerTokenUsageBreakdown, title: String) -> some View {
        Section(title) {
            LabeledContent("Total", value: count(usage.totalTokens))
            LabeledContent("Input", value: count(usage.inputTokens))
            LabeledContent("Cached input", value: count(usage.cachedInputTokens))
            LabeledContent("Cache writes", value: count(usage.cacheWriteInputTokens))
            LabeledContent("Output", value: count(usage.outputTokens))
            LabeledContent("Reasoning output", value: count(usage.reasoningOutputTokens))
        }
    }

    private func count(_ value: Int?) -> String { value.map { $0.formatted() } ?? "Not reported" }
}
