import XCTest
import Security
@testable import CodexAppMobile

final class AppServerConnectionTests: XCTestCase {
    func testSecureEndpointPreservesPathAndExplicitPort() throws {
        let endpoint = "wss://codex.example.test:8443/team/socket"
        XCTAssertEqual(try AppServerConnectionSecurity.endpoint("  \(endpoint)\n").absoluteString, endpoint)
        XCTAssertEqual(try AppServerConnectionSecurity.endpoint("ws://[::1]:8080/socket").absoluteString, "ws://[::1]:8080/socket")
    }

    func testInvalidOrCredentialBearingEndpointsAreRejected() {
        for endpoint in [
            "https://codex.example.test", "wss:///socket", "wss://host:0", "ws://host:65536",
            "wss://user:secret@host/socket", "wss://host/socket?token=secret", "wss://host/#secret",
            "wss://host/contains space", "host:8080",
        ] {
            XCTAssertThrowsError(try AppServerConnectionSecurity.endpoint(endpoint), endpoint)
        }
    }

    func testBearerHandshakeUsesOnlyItsSelectedCredentials() throws {
        let credentials = AppServerCredentials(authentication: .bearer, bearerToken: "test-bearer",
                                               clientID: "unused-id", clientSecret: "unused-secret")
        let request = try AppServerConnectionSecurity.request(endpoint: "wss://host/socket", credentials: credentials)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-bearer")
        XCTAssertNil(request.value(forHTTPHeaderField: "CF-Access-Client-Id"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(credentials.sanitizedForStorage.clientSecret, "")
    }

    func testCloudflareHandshakeAndNoAuthentication() throws {
        let credentials = AppServerCredentials(authentication: .cloudflareAccess,
                                               clientID: "client.access", clientSecret: "test-secret")
        let request = try AppServerConnectionSecurity.request(endpoint: "wss://host/socket", credentials: credentials)
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Id"), "client.access")
        XCTAssertEqual(request.value(forHTTPHeaderField: "CF-Access-Client-Secret"), "test-secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let anonymous = try AppServerConnectionSecurity.request(endpoint: "wss://host/socket", credentials: .empty)
        XCTAssertTrue(anonymous.allHTTPHeaderFields?.isEmpty ?? true)
    }

    func testTokensCannotBeSentOverPlainWebSocket() {
        for credentials in [
            AppServerCredentials(authentication: .bearer, bearerToken: "test-token"),
            AppServerCredentials(authentication: .cloudflareAccess, clientID: "id", clientSecret: "secret"),
        ] {
            XCTAssertThrowsError(try AppServerConnectionSecurity.request(endpoint: "ws://host:8080", credentials: credentials))
        }
    }

    func testMalformedHeaderValuesAndMissingSecretsFailBeforeConnecting() {
        for value in ["", "has space", "token\r\nInjected: yes", "token\u{0}", "токен"] {
            XCTAssertFalse(AppServerCredentials(authentication: .bearer, bearerToken: value).isValid)
        }
        XCTAssertThrowsError(try AppServerConnectionSecurity.request(
            endpoint: "wss://host", credentials: .empty, expectedAuthentication: .bearer
        )) { error in
            guard case AppServerConnectionError.missingCredentials = error else {
                return XCTFail("Expected missing credentials, received \(type(of: error))")
            }
        }
        XCTAssertThrowsError(try AppServerConnectionSecurity.request(
            endpoint: "wss://host", credentials: .init(authentication: .cloudflareAccess, clientID: "id"),
            expectedAuthentication: .cloudflareAccess
        ))
    }

    func testConnectionSessionDoesNotShareBrowserStorage() {
        let session = AppServerConnectionSecurity.makeSession()
        defer { session.invalidateAndCancel() }
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCredentialStorage)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
    }

    func testLegacyHostWithoutAuthenticationModeStillDecodes() throws {
        let host = Self.host()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
        object.removeValue(forKey: "appServerAuthentication")
        let decoded = try JSONDecoder().decode(RemoteHost.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.appServerAuthentication, .none)
        XCTAssertEqual(decoded.appServerURL, host.appServerURL)
        XCTAssertEqual(decoded.id, host.id)
    }

    @MainActor
    func testEditingHostPreservesSecureEndpointAndSecretsOutsideMetadata() throws {
        let suite = "EndpointEdit.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = TestAppServerCredentialStore()
        let store = RemoteHostStore(defaults: defaults, credentialStore: InMemoryHostCredentialStore(),
                                    appServerCredentialStore: credentials)
        var draft = Self.draft()
        draft.appServerCredentials = .init(authentication: .bearer, bearerToken: "private-test-token")
        XCTAssertTrue(store.upsert(hostID: nil, draft: draft))
        let host = try XCTUnwrap(store.hosts.first)
        var edited = RemoteHostDraft(host: host, password: "")
        edited.name = "Renamed"
        XCTAssertTrue(store.upsert(hostID: host.id, draft: edited))
        let reloaded = RemoteHostStore(defaults: defaults, credentialStore: InMemoryHostCredentialStore(),
                                       appServerCredentialStore: credentials)
        XCTAssertEqual(reloaded.hosts.first?.appServerURL, draft.appServerEndpoint)
        XCTAssertEqual(reloaded.hosts.first?.appServerAuthentication, .bearer)
        XCTAssertEqual(try reloaded.appServerCredentials(for: host.id).bearerToken, "private-test-token")
        let data = try XCTUnwrap(defaults.data(forKey: "codex.remote.hosts.v1"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-test-token"))
    }

    @MainActor
    func testFailedSecretWriteDoesNotChangeSavedHost() throws {
        let suite = "CredentialFailure.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = TestAppServerCredentialStore()
        let store = RemoteHostStore(defaults: defaults, credentialStore: InMemoryHostCredentialStore(),
                                    appServerCredentialStore: credentials)
        XCTAssertTrue(store.upsert(hostID: nil, draft: Self.draft()))
        let original = try XCTUnwrap(store.hosts.first)
        let storedData = defaults.data(forKey: "codex.remote.hosts.v1")
        var draft = RemoteHostDraft(host: original, password: "")
        draft.name = "Must not be saved"
        draft.appServerCredentials = .init(authentication: .bearer, bearerToken: "new-secret")
        credentials.failWrites = true
        XCTAssertFalse(store.upsert(hostID: original.id, draft: draft))
        XCTAssertEqual(store.hosts, [original])
        XCTAssertEqual(defaults.data(forKey: "codex.remote.hosts.v1"), storedData)
        XCTAssertFalse(store.credentialError.isEmpty)
    }

    @MainActor
    func testMissingKeychainItemKeepsAuthenticationModeForRecovery() throws {
        let suite = "CredentialRecovery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = TestAppServerCredentialStore()
        let store = RemoteHostStore(defaults: defaults, credentialStore: InMemoryHostCredentialStore(),
                                    appServerCredentialStore: credentials)
        var draft = Self.draft()
        draft.appServerCredentials = .init(authentication: .bearer, bearerToken: "test-token")
        XCTAssertTrue(store.upsert(hostID: nil, draft: draft))
        let host = try XCTUnwrap(store.hosts.first)
        credentials.values.removeAll()
        let recovered = try store.appServerCredentials(for: host.id)
        XCTAssertEqual(recovered.authentication, .bearer)
        XCTAssertFalse(recovered.isValid)
        XCTAssertFalse(store.upsert(hostID: host.id, draft: RemoteHostDraft(host: host, password: "")))
        XCTAssertEqual(store.hosts.first?.appServerAuthentication, .bearer)
    }

    @MainActor
    func testFailedCredentialDeletionRetainsHostAndPassword() throws {
        let suite = "CredentialDelete.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = TestAppServerCredentialStore()
        let passwords = InMemoryHostCredentialStore()
        let store = RemoteHostStore(defaults: defaults, credentialStore: passwords, appServerCredentialStore: credentials)
        var draft = Self.draft()
        draft.password = "test-ssh-password"
        XCTAssertTrue(store.upsert(hostID: nil, draft: draft))
        let host = try XCTUnwrap(store.hosts.first)
        credentials.failWrites = true
        XCTAssertFalse(store.delete(hostID: host.id))
        XCTAssertEqual(store.hosts, [host])
        XCTAssertEqual(passwords.readPassword(for: host.id), "test-ssh-password")
    }

    @MainActor
    func testAppServerOnlyHostDoesNotRequireSSHAndKeepsFullEndpoint() throws {
        let suite = "WSSOnlyHost.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hosts = RemoteHostStore(defaults: defaults,
                                    credentialStore: InMemoryHostCredentialStore(),
                                    appServerCredentialStore: TestAppServerCredentialStore())
        let draft = RemoteHostDraft(name: "WebSocket only", host: "", sshPort: 0,
                                    username: "", appServerHost: "", appServerPort: 0,
                                    preferredTransport: .appServerWS, password: "",
                                    appServerEndpoint: "wss://proxy.example.test:8443/team/socket")
        XCTAssertTrue(draft.isValid)
        XCTAssertTrue(hosts.upsert(hostID: nil, draft: draft))
        let host = try XCTUnwrap(hosts.hosts.first)
        XCTAssertFalse(host.hasSSHConfiguration)
        XCTAssertEqual(host.username, "")
        XCTAssertEqual(host.appServerURL, "wss://proxy.example.test:8443/team/socket")
        var edited = RemoteHostDraft(host: host, password: "")
        XCTAssertTrue(edited.isValid)
        edited.name = "Updated WebSocket"
        XCTAssertTrue(hosts.upsert(hostID: host.id, draft: edited))
        XCTAssertEqual(hosts.hosts.first?.appServerURL, draft.appServerEndpoint)
    }

    func testSSHStillRequiresCompleteFields() {
        var draft = RemoteHostDraft(name: "SSH Host", host: "", sshPort: 22,
                                    username: "", appServerHost: "", appServerPort: 8080,
                                    preferredTransport: .ssh, password: "",
                                    appServerEndpoint: "wss://server.example.test")
        XCTAssertFalse(draft.isValid)
        draft.host = "server.example.test"
        XCTAssertFalse(draft.isValid)
        draft.username = "developer"
        XCTAssertTrue(draft.isValid)
        draft.sshPort = 0
        XCTAssertFalse(draft.isValid)
        draft.preferredTransport = .appServerWS
        draft.host = ""
        draft.username = ""
        XCTAssertTrue(draft.isValid)
    }

    private static func host() -> RemoteHost {
        RemoteHost(name: "VPS", host: "host.example.test", sshPort: 22, username: "user",
                   appServerURL: "wss://proxy.example.test:8443/team/socket")
    }

    private static func draft() -> RemoteHostDraft {
        RemoteHostDraft(host: self.host(), password: "")
    }
}

final class TestAppServerCredentialStore: AppServerCredentialStore {
    var values: [UUID: AppServerCredentials] = [:]
    var failWrites = false
    var failReads = false

    func read(for hostID: UUID) throws -> AppServerCredentials {
        if failReads { throw AppServerConnectionError.keychain(errSecInteractionNotAllowed) }
        return values[hostID] ?? .empty
    }

    func save(_ credentials: AppServerCredentials, for hostID: UUID) throws {
        if failWrites { throw AppServerConnectionError.keychain(errSecInteractionNotAllowed) }
        values[hostID] = credentials.sanitizedForStorage
    }

    func delete(for hostID: UUID) throws {
        if failWrites { throw AppServerConnectionError.keychain(errSecInteractionNotAllowed) }
        values.removeValue(forKey: hostID)
    }
}
