import XCTest
@testable import CodexAppMobile

final class HostConfigurationTests: XCTestCase {
    func testWSSOnlyDraftNeedsNoSSHFieldsOrPort() {
        let draft = Self.wssDraft()
        XCTAssertTrue(draft.isValid)
        XCTAssertFalse(draft.usesSSH)
        XCTAssertEqual(draft.resolvedAppServerURL, "wss://codex.example.test/team/socket")
    }

    func testWSSOnlyDraftStillValidatesEndpointAndAuthentication() {
        var draft = Self.wssDraft()
        draft.appServerCredentials = .init(authentication: .bearer, bearerToken: "test-token")
        XCTAssertTrue(draft.isValid)
        draft.appServerEndpoint = "ws://codex.example.test/socket"
        XCTAssertFalse(draft.isValid)
        draft.appServerEndpoint = "wss://codex.example.test/socket?token=secret"
        XCTAssertFalse(draft.isValid)
        draft.appServerEndpoint = "wss://codex.example.test/socket"
        draft.appServerCredentials = .init(authentication: .bearer)
        XCTAssertFalse(draft.isValid)
        draft.name = "  "
        draft.appServerCredentials = .empty
        XCTAssertFalse(draft.isValid)
    }

    func testEnabledSSHFallbackRequiresCompleteFields() {
        var draft = Self.wssDraft()
        draft.sshFallbackEnabled = true
        XCTAssertFalse(draft.isValid)
        draft.host = "ssh.example.test"
        draft.sshPort = 22
        XCTAssertFalse(draft.isValid)
        draft.username = "user"
        XCTAssertTrue(draft.isValid)
        draft.sshPort = 65_536
        XCTAssertFalse(draft.isValid)
        draft.sshFallbackEnabled = false
        XCTAssertTrue(draft.isValid)
    }

    func testSSHTransportRequiresFieldsEvenIfFallbackSwitchIsOff() {
        var draft = Self.wssDraft()
        draft.preferredTransport = .ssh
        XCTAssertFalse(draft.isValid)
        draft.host = "ssh.example.test"
        draft.username = "user"
        draft.sshPort = 22
        XCTAssertTrue(draft.isValid)
        XCTAssertTrue(draft.usesSSH)
    }

    func testExistingSSHFallbackSurvivesEditorRoundTrip() {
        let host = Self.sshHost()
        let draft = RemoteHostDraft(host: host, password: "ssh-secret")
        XCTAssertTrue(draft.sshFallbackEnabled)
        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(draft.host, host.host)
        XCTAssertEqual(draft.username, host.username)
        XCTAssertEqual(draft.sshPort, host.sshPort)
        XCTAssertEqual(draft.password, "ssh-secret")
        XCTAssertEqual(draft.appServerEndpoint, host.appServerURL)
    }

    func testAppServerRecordCanDecodeWithoutSSHKeys() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.sshHost())) as? [String: Any])
        for key in ["host", "username", "sshPort"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(RemoteHost.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.hasSSHConfiguration)
        XCTAssertEqual(decoded.preferredTransport, .appServerWS)
        XCTAssertEqual(decoded.appServerURL, Self.sshHost().appServerURL)
        XCTAssertTrue(RemoteHostDraft(host: decoded, password: "").isValid)
    }

    @MainActor
    func testWSSOnlyStoreRoundTripAndSecretIsolation() throws {
        let suite = "WSSOnly.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = TestAppServerCredentialStore()
        let passwords = InMemoryHostCredentialStore()
        let store = RemoteHostStore(defaults: defaults, credentialStore: passwords, appServerCredentialStore: credentials)
        var draft = Self.wssDraft()
        draft.appServerCredentials = .init(authentication: .bearer, bearerToken: "private-fixture-token")
        XCTAssertTrue(store.upsert(hostID: nil, draft: draft))
        let host = try XCTUnwrap(store.hosts.first)
        XCTAssertFalse(host.hasSSHConfiguration)
        XCTAssertEqual(host.host, "")
        XCTAssertEqual(host.username, "")
        XCTAssertNil(passwords.readPassword(for: host.id))
        let loaded = RemoteHostStore(defaults: defaults, credentialStore: passwords, appServerCredentialStore: credentials)
        XCTAssertEqual(loaded.hosts, [host])
        XCTAssertEqual(try loaded.appServerCredentials(for: host.id).bearerToken, "private-fixture-token")
        let metadata = try XCTUnwrap(defaults.data(forKey: "codex.remote.hosts.v1"))
        XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains("private-fixture-token"))
    }

    @MainActor
    func testDisablingFallbackRemovesOnlySSHConfigurationAndPassword() throws {
        let suite = "RemoveSSH.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = TestAppServerCredentialStore()
        let passwords = InMemoryHostCredentialStore()
        let store = RemoteHostStore(defaults: defaults, credentialStore: passwords, appServerCredentialStore: credentials)
        var draft = RemoteHostDraft(host: Self.sshHost(), password: "ssh-secret")
        draft.appServerCredentials = .init(authentication: .bearer, bearerToken: "codex-secret")
        XCTAssertTrue(store.upsert(hostID: nil, draft: draft))
        let original = try XCTUnwrap(store.hosts.first)
        draft.sshFallbackEnabled = false
        XCTAssertTrue(store.upsert(hostID: original.id, draft: draft))
        let saved = try XCTUnwrap(store.hosts.first)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.appServerURL, original.appServerURL)
        XCTAssertFalse(saved.hasSSHConfiguration)
        XCTAssertEqual(saved.host, "")
        XCTAssertEqual(saved.username, "")
        XCTAssertNil(passwords.readPassword(for: saved.id))
        XCTAssertEqual(try store.appServerCredentials(for: saved.id).bearerToken, "codex-secret")
    }

    @MainActor
    func testFailedCredentialWriteDoesNotDisableExistingSSH() throws {
        let suite = "RetainSSH.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = TestAppServerCredentialStore()
        let passwords = InMemoryHostCredentialStore()
        let store = RemoteHostStore(defaults: defaults, credentialStore: passwords, appServerCredentialStore: credentials)
        var draft = RemoteHostDraft(host: Self.sshHost(), password: "ssh-secret")
        XCTAssertTrue(store.upsert(hostID: nil, draft: draft))
        let original = try XCTUnwrap(store.hosts.first)
        draft.sshFallbackEnabled = false
        draft.appServerCredentials = .init(authentication: .bearer, bearerToken: "test-token")
        credentials.failWrites = true
        XCTAssertFalse(store.upsert(hostID: original.id, draft: draft))
        XCTAssertEqual(store.hosts, [original])
        XCTAssertEqual(passwords.readPassword(for: original.id), "ssh-secret")
    }

    func testSSHServicesRejectMissingConfigurationBeforeConnecting() async throws {
        let host = RemoteHost(name: "WSS", host: "", sshPort: 0, username: "",
                              appServerURL: "wss://codex.example.test", preferredTransport: .appServerWS)
        do {
            _ = try await SSHCodexExecService().checkCodexVersion(host: host, password: "")
            XCTFail("An SSH connection must not start for a WSS-only host")
        } catch RemoteHostConfigurationError.missingSSH {} catch { XCTFail("Unexpected error: \(error)") }
        do {
            _ = try await SSHGitService().loadDiff(host: host, password: "", workspacePath: "/repo")
            XCTFail("SSH Git must not connect for a WSS-only host")
        } catch RemoteHostConfigurationError.missingSSH {} catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testWorktreeRegistrationPreservesExactPathsAndIsScopedToHost() throws {
        let suite = "WorktreeRegistration.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(defaults: defaults)
        let source = ProjectWorkspace(hostID: UUID(), name: "Source", remotePath: "/repo",
                                      defaultModel: "test-model", defaultApprovalPolicy: .untrusted)
        let path = "/worktrees/feature with spaces\n"
        let first = store.registerWorktree(path: path, inheriting: source)
        let repeated = store.registerWorktree(path: path, inheriting: source)
        XCTAssertEqual(first.id, repeated.id)
        XCTAssertEqual(first.remotePath, path)
        XCTAssertEqual(first.defaultModel, source.defaultModel)
        XCTAssertEqual(first.defaultApprovalPolicy, .untrusted)
        var otherHost = source
        otherHost.hostID = UUID()
        let other = store.registerWorktree(path: path, inheriting: otherHost)
        XCTAssertNotEqual(other.id, first.id)
        let reloaded = ProjectStore(defaults: defaults)
        XCTAssertEqual(reloaded.workspaces.count, 2)
        XCTAssertTrue(reloaded.workspaces.allSatisfy { $0.remotePath == path })
    }

    private static func wssDraft() -> RemoteHostDraft {
        RemoteHostDraft(name: "VPS", host: "", sshPort: 0, username: "", appServerHost: "",
                        appServerPort: 0, preferredTransport: .appServerWS, password: "",
                        appServerEndpoint: "wss://codex.example.test/team/socket")
    }

    private static func sshHost() -> RemoteHost {
        RemoteHost(name: "VPS", host: "ssh.example.test", sshPort: 2222, username: "user",
                   appServerURL: "wss://codex.example.test/team/socket", preferredTransport: .appServerWS)
    }
}
