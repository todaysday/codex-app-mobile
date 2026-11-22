import Foundation
import SwiftUI

@MainActor
final class RemoteHostStore: ObservableObject {
    @Published private(set) var hosts: [RemoteHost] = []
    @Published private(set) var credentialError = ""

    private let defaults: UserDefaults
    private let credentialStore: HostCredentialStore
    private let appServerCredentialStore: AppServerCredentialStore

    private let hostsKey = "codex.remote.hosts.v1"
    private let legacyRemoteHostsKey = "codex.remote.connections.v1"
    private let legacyProfilesKey = "ssh.connection.profiles.v1"

    init(
        defaults: UserDefaults = .standard,
        credentialStore: HostCredentialStore = KeychainHostCredentialStore(),
        appServerCredentialStore: AppServerCredentialStore = KeychainAppServerCredentialStore()
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        self.appServerCredentialStore = appServerCredentialStore
        self.loadHosts()
    }

    @discardableResult
    func upsert(hostID: UUID?, draft: RemoteHostDraft) -> Bool {
        self.credentialError = ""
        guard draft.isValid else {
            self.credentialError = "Check the host details and secure connection settings."
            return false
        }
        let recordID = hostID ?? UUID()
        let existingAuthentication = self.hosts.first { $0.id == recordID }?.appServerAuthentication ?? .none
        let authentication: AppServerAuthentication
        do {
            let credentials: AppServerCredentials
            if let supplied = draft.appServerCredentials {
                credentials = supplied
            } else if existingAuthentication == .none {
                credentials = .empty
            } else {
                credentials = try self.appServerCredentialStore.read(for: recordID)
            }
            _ = try AppServerConnectionSecurity.request(
                endpoint: draft.resolvedAppServerURL,
                credentials: credentials,
                expectedAuthentication: draft.appServerCredentials == nil ? existingAuthentication : credentials.authentication
            )
            authentication = credentials.authentication
            if draft.appServerCredentials != nil {
                try self.appServerCredentialStore.save(credentials, for: recordID)
            }
        } catch {
            self.credentialError = "Could not validate or save connection credentials. The host was not changed. Edit the host and check its credentials."
            return false
        }
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = draft.usesSSH ? draft.host.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let trimmedUser = draft.usesSSH ? draft.username.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let sshPort = draft.usesSSH ? draft.sshPort : 22
        let resolvedAppServerURL = draft.resolvedAppServerURL
        var updatedHosts = self.hosts

        if let hostID,
           let index = updatedHosts.firstIndex(where: { $0.id == hostID }) {
            var hostRecord = updatedHosts[index]
            hostRecord.name = trimmedName
            hostRecord.host = trimmedHost
            hostRecord.sshPort = sshPort
            hostRecord.username = trimmedUser
            hostRecord.appServerURL = resolvedAppServerURL
            hostRecord.appServerAuthentication = authentication
            hostRecord.preferredTransport = draft.preferredTransport
            hostRecord.updatedAt = Date()
            updatedHosts[index] = hostRecord
        } else {
            let hostRecord = RemoteHost(
                id: recordID,
                name: trimmedName,
                host: trimmedHost,
                sshPort: sshPort,
                username: trimmedUser,
                appServerURL: resolvedAppServerURL,
                appServerAuthentication: authentication,
                preferredTransport: draft.preferredTransport
            )
            updatedHosts.append(hostRecord)
        }

        if draft.usesSSH {
            self.credentialStore.save(password: draft.password, for: recordID)
        } else {
            self.credentialStore.deletePassword(for: recordID)
        }
        self.replaceHosts(updatedHosts, persist: true)
        return true
    }

    @discardableResult
    func delete(hostID: UUID) -> Bool {
        self.credentialError = ""
        do {
            try self.appServerCredentialStore.delete(for: hostID)
        } catch {
            self.credentialError = "Could not remove connection credentials from Keychain. The host was kept."
            return false
        }
        self.replaceHosts(self.hosts.filter { $0.id != hostID }, persist: true)
        self.credentialStore.deletePassword(for: hostID)
        return true
    }

    func appServerCredentials(for hostID: UUID) throws -> AppServerCredentials {
        let credentials = try self.appServerCredentialStore.read(for: hostID)
        let expected = self.hosts.first { $0.id == hostID }?.appServerAuthentication ?? .none
        // Missing secrets must preserve the chosen mode so the editor asks for re-entry.
        return credentials.authentication == expected ? credentials : AppServerCredentials(authentication: expected)
    }

    func password(for hostID: UUID) -> String {
        self.credentialStore.readPassword(for: hostID) ?? ""
    }

    func updatePassword(_ password: String, for hostID: UUID) {
        self.credentialStore.save(password: password, for: hostID)
    }

    private func loadHosts() {
        if let data = self.defaults.data(forKey: self.hostsKey),
           let decoded = try? JSONDecoder().decode([RemoteHost].self, from: data) {
            self.replaceHosts(decoded, persist: false)
            return
        }

        if let data = self.defaults.data(forKey: self.legacyRemoteHostsKey),
           let decoded = try? JSONDecoder().decode([RemoteHost].self, from: data) {
            self.replaceHosts(decoded, persist: true)
            return
        }

        self.replaceHosts(self.migrateFromLegacyProfilesIfNeeded(), persist: true)
    }

    private func migrateFromLegacyProfilesIfNeeded() -> [RemoteHost] {
        guard let data = self.defaults.data(forKey: self.legacyProfilesKey),
              let legacyProfiles = try? JSONDecoder().decode([SSHHostProfile].self, from: data)
        else {
            return []
        }

        return legacyProfiles.map { profile in
            RemoteHost(
                id: profile.id,
                name: profile.name,
                host: profile.host,
                sshPort: profile.port,
                username: profile.username,
                appServerURL: RemoteHost.defaultAppServerURL(host: profile.host)
            )
        }
    }

    private func replaceHosts(_ hosts: [RemoteHost], persist: Bool) {
        self.hosts = hosts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if persist {
            self.persistHosts()
        }
    }

    private func persistHosts() {
        guard let data = try? JSONEncoder().encode(self.hosts) else {
            self.defaults.removeObject(forKey: self.hostsKey)
            return
        }
        self.defaults.set(data, forKey: self.hostsKey)
    }
}

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var workspaces: [ProjectWorkspace] = []

    private let defaults: UserDefaults
    private let workspacesKey = "codex.project.workspaces.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.loadWorkspaces()
    }

    func workspaces(for hostID: UUID?) -> [ProjectWorkspace] {
        guard let hostID else { return [] }
        return self.workspaces.filter { $0.hostID == hostID }
    }

    @discardableResult
    func upsert(workspaceID: UUID?, hostID: UUID, draft: ProjectWorkspaceDraft) -> UUID {
        let trimmedPath = draft.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = draft.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedWorkspaceID: UUID

        if let workspaceID,
           let index = self.workspaces.firstIndex(where: { $0.id == workspaceID }) {
            self.workspaces[index].hostID = hostID
            self.workspaces[index].name = trimmedName
            self.workspaces[index].remotePath = trimmedPath
            self.workspaces[index].defaultModel = trimmedModel
            self.workspaces[index].defaultApprovalPolicy = draft.defaultApprovalPolicy
            self.workspaces[index].updatedAt = Date()
            resolvedWorkspaceID = workspaceID
        } else {
            let workspace = ProjectWorkspace(
                hostID: hostID,
                name: trimmedName,
                remotePath: trimmedPath,
                defaultModel: trimmedModel,
                defaultApprovalPolicy: draft.defaultApprovalPolicy
            )
            self.workspaces.append(workspace)
            resolvedWorkspaceID = workspace.id
        }

        self.sortAndPersist()
        return resolvedWorkspaceID
    }

    func registerWorktree(path: String, inheriting source: ProjectWorkspace) -> ProjectWorkspace {
        if let existing = self.workspaces.first(where: { $0.hostID == source.hostID && $0.remotePath == path }) {
            return existing
        }
        // Git paths are already validated by the caller. Preserve significant whitespace.
        let workspace = ProjectWorkspace(hostID: source.hostID, name: "", remotePath: path,
                                         defaultModel: source.defaultModel,
                                         defaultApprovalPolicy: source.defaultApprovalPolicy)
        self.workspaces.append(workspace)
        self.sortAndPersist()
        return workspace
    }

    func delete(workspaceID: UUID) {
        self.workspaces.removeAll(where: { $0.id == workspaceID })
        self.persistWorkspaces()
    }

    private func loadWorkspaces() {
        guard let data = self.defaults.data(forKey: self.workspacesKey),
              let decoded = try? JSONDecoder().decode([ProjectWorkspace].self, from: data)
        else {
            self.workspaces = []
            return
        }

        self.workspaces = decoded
        self.workspaces.sort(by: Self.compare)
    }

    private func sortAndPersist() {
        self.workspaces.sort(by: Self.compare)
        self.persistWorkspaces()
    }

    private func persistWorkspaces() {
        guard let data = try? JSONEncoder().encode(self.workspaces) else {
            self.defaults.removeObject(forKey: self.workspacesKey)
            return
        }
        self.defaults.set(data, forKey: self.workspacesKey)
    }

    private static func compare(lhs: ProjectWorkspace, rhs: ProjectWorkspace) -> Bool {
        if lhs.hostID != rhs.hostID {
            return lhs.hostID.uuidString < rhs.hostID.uuidString
        }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
}

@MainActor
final class ThreadBookmarkStore: ObservableObject {
    @Published private(set) var bookmarks: [CodexThreadSummary] = []

    private let defaults: UserDefaults
    private let bookmarksKey = "codex.thread.bookmarks.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.load()
    }

    func threads(for workspaceID: UUID?) -> [CodexThreadSummary] {
        guard let workspaceID else { return [] }
        return self.bookmarks
            .filter { $0.workspaceID == workspaceID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func upsert(summary: CodexThreadSummary) {
        if let index = self.bookmarks.firstIndex(where: {
            $0.threadID == summary.threadID && $0.workspaceID == summary.workspaceID
        }) {
            self.bookmarks[index] = summary
        } else {
            self.bookmarks.append(summary)
        }
        self.persist()
    }

    func replaceThreads(for workspaceID: UUID, hostID: UUID, with summaries: [CodexThreadSummary]) {
        self.bookmarks.removeAll(where: { $0.workspaceID == workspaceID && $0.hostID == hostID })
        self.bookmarks.append(contentsOf: summaries)
        self.persist()
    }

    func remove(threadID: String, workspaceID: UUID) {
        self.bookmarks.removeAll(where: { $0.threadID == threadID && $0.workspaceID == workspaceID })
        self.persist()
    }

    private func load() {
        guard let data = self.defaults.data(forKey: self.bookmarksKey),
              let decoded = try? JSONDecoder().decode([CodexThreadSummary].self, from: data)
        else {
            self.bookmarks = []
            return
        }
        self.bookmarks = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(self.bookmarks) else {
            self.defaults.removeObject(forKey: self.bookmarksKey)
            return
        }
        self.defaults.set(data, forKey: self.bookmarksKey)
    }
}

struct TerminalLaunchContext: Equatable, Identifiable {
    let id: UUID = UUID()
    let hostID: UUID
    let projectPath: String?
    let threadID: String?
    let initialCommand: String
}

struct HostSessionContext: Identifiable, Codable, Equatable {
    var id: UUID { self.hostID }
    let hostID: UUID
    var selectedProjectID: UUID?
    var selectedThreadID: String?
    var lastActiveAt: Date
    var lastOpenedAt: Date
}

@MainActor
final class HostSessionStore: ObservableObject {
    @Published private(set) var sessions: [HostSessionContext] = []

    private let defaults: UserDefaults
    private let key = "codex.host.sessions.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.load()
    }

    func session(for hostID: UUID) -> HostSessionContext? {
        self.sessions.first(where: { $0.hostID == hostID })
    }

    func upsertSession(hostID: UUID) {
        let now = Date()
        if let index = self.sessions.firstIndex(where: { $0.hostID == hostID }) {
            self.sessions[index].lastActiveAt = now
        } else {
            self.sessions.append(
                HostSessionContext(
                    hostID: hostID,
                    selectedProjectID: nil,
                    selectedThreadID: nil,
                    lastActiveAt: now,
                    lastOpenedAt: now
                )
            )
        }
        self.persist()
    }

    func markOpened(hostID: UUID) {
        let now = Date()
        if let index = self.sessions.firstIndex(where: { $0.hostID == hostID }) {
            self.sessions[index].lastOpenedAt = now
            self.sessions[index].lastActiveAt = now
        } else {
            self.sessions.append(
                HostSessionContext(
                    hostID: hostID,
                    selectedProjectID: nil,
                    selectedThreadID: nil,
                    lastActiveAt: now,
                    lastOpenedAt: now
                )
            )
        }
        self.persist()
    }

    func selectProject(hostID: UUID, projectID: UUID?) {
        self.upsertSession(hostID: hostID)
        guard let index = self.sessions.firstIndex(where: { $0.hostID == hostID }) else { return }
        self.sessions[index].selectedProjectID = projectID
        if projectID == nil {
            self.sessions[index].selectedThreadID = nil
        }
        self.sessions[index].lastActiveAt = Date()
        self.persist()
    }

    func selectThread(hostID: UUID, threadID: String?) {
        self.upsertSession(hostID: hostID)
        guard let index = self.sessions.firstIndex(where: { $0.hostID == hostID }) else { return }
        self.sessions[index].selectedThreadID = threadID
        self.sessions[index].lastActiveAt = Date()
        self.persist()
    }

    func removeSession(hostID: UUID) {
        self.sessions.removeAll(where: { $0.hostID == hostID })
        self.persist()
    }

    func cleanupOrphans(validHostIDs: Set<UUID>) {
        self.sessions.removeAll(where: { validHostIDs.contains($0.hostID) == false })
        self.persist()
    }

    private func load() {
        guard let data = self.defaults.data(forKey: self.key),
              let decoded = try? JSONDecoder().decode([HostSessionContext].self, from: data)
        else {
            self.sessions = []
            return
        }
        self.sessions = decoded.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    private func persist() {
        self.sessions.sort { $0.lastActiveAt > $1.lastActiveAt }
        guard let data = try? JSONEncoder().encode(self.sessions) else {
            self.defaults.removeObject(forKey: self.key)
            return
        }
        self.defaults.set(data, forKey: self.key)
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedHostID: UUID?
    @Published var terminalLaunchContext: TerminalLaunchContext?
    @Published var composerDraftStore = CodexComposerDraftStore()

    let remoteHostStore: RemoteHostStore
    let projectStore: ProjectStore
    let threadBookmarkStore: ThreadBookmarkStore
    let hostSessionStore: HostSessionStore
    let appServerClient: AppServerClient

    init(
        remoteHostStore: RemoteHostStore = RemoteHostStore(),
        projectStore: ProjectStore = ProjectStore(),
        threadBookmarkStore: ThreadBookmarkStore = ThreadBookmarkStore(),
        hostSessionStore: HostSessionStore = HostSessionStore(),
        appServerClient: AppServerClient = AppServerClient()
    ) {
        self.remoteHostStore = remoteHostStore
        self.projectStore = projectStore
        self.threadBookmarkStore = threadBookmarkStore
        self.hostSessionStore = hostSessionStore
        self.appServerClient = appServerClient

        self.selectedHostID = remoteHostStore.hosts.first?.id
        self.cleanupSessionOrphans()
    }

    var selectedHost: RemoteHost? {
        guard let selectedHostID else { return nil }
        return self.remoteHostStore.hosts.first(where: { $0.id == selectedHostID })
    }

    func selectHost(_ hostID: UUID?) {
        self.selectedHostID = hostID
        if let hostID {
            self.hostSessionStore.upsertSession(hostID: hostID)
        }
    }

    func removeHost(hostID: UUID) {
        guard self.remoteHostStore.delete(hostID: hostID) else { return }
        self.hostSessionStore.removeSession(hostID: hostID)
        self.projectStore.workspaces
            .filter { $0.hostID == hostID }
            .forEach { workspace in
                self.threadBookmarkStore
                    .threads(for: workspace.id)
                    .forEach { summary in
                        self.threadBookmarkStore.remove(threadID: summary.threadID, workspaceID: workspace.id)
                    }
                self.projectStore.delete(workspaceID: workspace.id)
            }
        if self.selectedHostID == hostID {
            self.selectedHostID = self.remoteHostStore.hosts.first?.id
        }
        self.cleanupSessionOrphans()
    }

    func removeWorkspace(hostID: UUID, workspaceID: UUID, replacementWorkspaceID: UUID? = nil) {
        self.threadBookmarkStore
            .threads(for: workspaceID)
            .forEach { summary in
                self.threadBookmarkStore.remove(threadID: summary.threadID, workspaceID: workspaceID)
            }
        self.projectStore.delete(workspaceID: workspaceID)

        guard let session = self.hostSessionStore.session(for: hostID),
              session.selectedProjectID == workspaceID else {
            return
        }

        self.hostSessionStore.selectProject(hostID: hostID, projectID: replacementWorkspaceID)
        self.hostSessionStore.selectThread(hostID: hostID, threadID: nil)
    }

    func cleanupSessionOrphans() {
        let validHostIDs = Set(self.remoteHostStore.hosts.map(\.id))
        self.hostSessionStore.cleanupOrphans(validHostIDs: validHostIDs)
    }
}
