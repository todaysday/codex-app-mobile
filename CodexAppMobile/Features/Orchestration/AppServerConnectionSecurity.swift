import Foundation
import Security

enum AppServerAuthentication: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case bearer
    case cloudflareAccess

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .none: "None (private connection)"
        case .bearer: "Bearer token"
        case .cloudflareAccess: "Cloudflare Access service token"
        }
    }
}

/// These values are stored together in Keychain, never in a host's Codable metadata.
struct AppServerCredentials: Codable, Equatable, Sendable {
    var authentication: AppServerAuthentication = .none
    var bearerToken = ""
    var clientID = ""
    var clientSecret = ""

    static let empty = AppServerCredentials()

    var isValid: Bool {
        switch self.authentication {
        case .none: true
        case .bearer: Self.isHeaderValue(self.bearerToken)
        case .cloudflareAccess: Self.isHeaderValue(self.clientID) && Self.isHeaderValue(self.clientSecret)
        }
    }

    var sanitizedForStorage: Self {
        switch self.authentication {
        case .none: .empty
        case .bearer: Self(authentication: .bearer, bearerToken: self.bearerToken)
        case .cloudflareAccess:
            Self(authentication: .cloudflareAccess, clientID: self.clientID, clientSecret: self.clientSecret)
        }
    }

    func apply(to request: inout URLRequest) throws {
        guard self.isValid else { throw AppServerConnectionError.invalidCredentials }
        guard self.authentication != .none else { return }
        guard request.url?.scheme?.lowercased() == "wss" else {
            throw AppServerConnectionError.credentialsRequireTLS
        }
        switch self.authentication {
        case .none: break
        case .bearer:
            request.setValue("Bearer \(self.bearerToken)", forHTTPHeaderField: "Authorization")
        case .cloudflareAccess:
            request.setValue(self.clientID, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(self.clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
    }

    private static func isHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 > 32 && $0 < 127 }
    }
}

enum AppServerConnectionError: LocalizedError {
    case invalidEndpoint
    case invalidCredentials
    case missingCredentials
    case credentialsRequireTLS
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "Enter a WebSocket URL with a host and no username, password, query, or fragment."
        case .invalidCredentials:
            "Complete the selected authentication fields without spaces or control characters."
        case .missingCredentials:
            "The saved connection credentials are unavailable. Edit this host and enter its credentials again."
        case .credentialsRequireTLS:
            "Connection tokens require a secure wss:// endpoint."
        case .keychain(let status):
            "Could not access connection credentials in Keychain (\(status))."
        }
    }
}

enum AppServerConnectionSecurity {
    static func endpoint(_ raw: String) throws -> URL {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.contains(where: { $0.isWhitespace || $0.isNewline }),
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              ["wss", "ws"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let url = components.url
        else { throw AppServerConnectionError.invalidEndpoint }
        return url
    }

    static func request(
        endpoint: String,
        credentials: AppServerCredentials,
        expectedAuthentication: AppServerAuthentication? = nil
    ) throws -> URLRequest {
        if let expectedAuthentication, credentials.authentication != expectedAuthentication {
            throw AppServerConnectionError.missingCredentials
        }
        var request = URLRequest(url: try self.endpoint(endpoint))
        request.httpShouldHandleCookies = false
        try credentials.apply(to: &request)
        return request
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: AppServerRedirectDelegate(), delegateQueue: nil)
    }
}

/// Connection credentials belong to the configured endpoint; redirects must not forward them.
private final class AppServerRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

protocol AppServerCredentialStore {
    func read(for hostID: UUID) throws -> AppServerCredentials
    func save(_ credentials: AppServerCredentials, for hostID: UUID) throws
    func delete(for hostID: UUID) throws
}

struct KeychainAppServerCredentialStore: AppServerCredentialStore {
    private let service = "dev.todaysday.codexmobile.app-server"

    private func query(for hostID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: hostID.uuidString,
        ]
    }

    func read(for hostID: UUID) throws -> AppServerCredentials {
        var query = self.query(for: hostID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return .empty }
        guard status == errSecSuccess, let data = value as? Data else {
            throw AppServerConnectionError.keychain(status)
        }
        return try JSONDecoder().decode(AppServerCredentials.self, from: data)
    }

    func save(_ credentials: AppServerCredentials, for hostID: UUID) throws {
        guard credentials.isValid else { throw AppServerConnectionError.invalidCredentials }
        if credentials.authentication == .none {
            try self.delete(for: hostID)
            return
        }
        let data = try JSONEncoder().encode(credentials.sanitizedForStorage)
        let query = self.query(for: hostID)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AppServerConnectionError.keychain(status) }
        var addition = query
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw AppServerConnectionError.keychain(addStatus) }
    }

    func delete(for hostID: UUID) throws {
        let status = SecItemDelete(self.query(for: hostID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppServerConnectionError.keychain(status)
        }
    }
}
