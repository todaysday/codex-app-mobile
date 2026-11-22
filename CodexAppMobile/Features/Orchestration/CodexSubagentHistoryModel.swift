import Combine
import Foundation

@MainActor
final class CodexSubagentHistoryModel: ObservableObject {
    struct Scope: Equatable, Hashable {
        let threadID: String
        let generation: Int
    }

    @Published private(set) var turns: [CodexAgentHistoryTurn] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?
    private(set) var scope: Scope?
    private var requestToken: UUID?

    var hasActiveTurn: Bool { turns.contains { $0.status == "inProgress" } }

    func prepare(threadID: String, generation: Int) {
        let newScope = Scope(threadID: threadID, generation: generation)
        guard scope != newScope else { return }
        scope = newScope
        requestToken = nil
        turns = []
        hasLoaded = false
        isLoading = false
        errorMessage = nil
    }

    func matches(threadID: String, generation: Int) -> Bool {
        scope == Scope(threadID: threadID, generation: generation)
    }

    func cancelRefresh() {
        requestToken = nil
        isLoading = false
    }

    func refresh(client: AppServerClient, threadID: String) async {
        let generation = client.connectionGeneration
        prepare(threadID: threadID, generation: generation)
        guard !isLoading, client.state == .connected, !Task.isCancelled else { return }
        let token = UUID()
        requestToken = token
        isLoading = true
        errorMessage = nil
        defer {
            if requestToken == token {
                requestToken = nil
                isLoading = false
            }
            if matches(threadID: threadID, generation: generation), generation != client.connectionGeneration {
                prepare(threadID: threadID, generation: client.connectionGeneration)
            }
        }
        do {
            let snapshot = try await client.threadRead(threadID: threadID)
            guard !Task.isCancelled, requestToken == token,
                  matches(threadID: threadID, generation: generation),
                  generation == client.connectionGeneration else { return }
            guard snapshot.threadID == threadID else { throw AppServerClientError.malformedResponse }
            turns = snapshot.turns.map(CodexAgentHistoryTurn.init)
            hasLoaded = true
        } catch {
            guard !Task.isCancelled, requestToken == token,
                  matches(threadID: threadID, generation: generation),
                  generation == client.connectionGeneration else { return }
            errorMessage = client.userFacingMessage(for: error)
        }
    }
}
