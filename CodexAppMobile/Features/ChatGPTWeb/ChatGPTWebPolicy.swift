import Foundation

enum ChatGPTWebPolicy {
    static let homeURL = URL(string: "https://chatgpt.com")!
    // Keep this identifier stable across launches and releases.
    static let storeIdentifier = UUID(uuidString: "70E5ABF8-5C6B-4E75-A7F1-FF38825C26D3")!
    // Independent from the deployed original store above.
    static let secondaryStoreIdentifier = UUID(uuidString: "9B741BD4-7E46-4BA7-94A1-F339E33CB251")!

    enum Navigation: Equatable {
        case allow
        case external
        case block
    }

    static func navigation(to url: URL?, isMainFrame: Bool) -> Navigation {
        guard let url else { return .block }
        if url.absoluteString == "about:blank" { return .allow }
        if url.scheme?.lowercased() == "blob" {
            let source = URL(string: String(url.absoluteString.dropFirst(5)))
            return isSecureURL(source) && isChatGPTHost(source?.host) ? .allow : .block
        }
        guard isSecureURL(url) else { return .block }
        // Cross-origin HTTPS frames are needed by login and bot-protection providers.
        guard isMainFrame else { return .allow }
        return isEmbeddedHost(url.host) ? .allow : .external
    }

    static func isSecureURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return true
    }

    static func isChatGPTHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "chatgpt.com" || host == "www.chatgpt.com"
    }

    static func isEmbeddedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let domains = ["chatgpt.com", "openai.com", "oaiusercontent.com"]
        if domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return true
        }
        return [
            "accounts.google.com", "appleid.apple.com", "idmsa.apple.com",
            "login.microsoftonline.com", "login.live.com"
        ].contains(host)
    }

    static func allowsMedia(scheme: String, host: String, port: Int) -> Bool {
        scheme.lowercased() == "https" && isChatGPTHost(host) && (port == 0 || port == 443)
    }

    static func safeFilename(_ suggestedFilename: String) -> String {
        let component = suggestedFilename.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").last.map(String.init) ?? "download"
        let allowed = component.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != ":"
        }
        let name = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { return "download" }
        var bounded = ""
        for character in name {
            if bounded.utf8.count + String(character).utf8.count > 180 { break }
            bounded.append(character)
        }
        return bounded.isEmpty ? "download" : bounded
    }
}

struct ChatGPTWebFailure: Equatable {
    let message: String
    let code: String

    static func navigation(_ error: Error) -> ChatGPTWebFailure? {
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return nil }
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return .init(message: "The internet connection was interrupted. Reconnect and reload.", code: "network")
            case NSURLErrorTimedOut:
                return .init(message: "The page took too long to respond. Try reloading.", code: "timeout")
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid:
                return .init(message: "A secure connection could not be verified. Try again on a trusted network.", code: "tls")
            default:
                return .init(message: "The page could not be loaded. Reload or open ChatGPT in the browser.", code: "url-\(error.code)")
            }
        }
        // Do not expose localizedDescription or userInfo: they may contain OAuth URLs.
        return .init(message: "The web page could not continue. Reload or open ChatGPT in the browser.", code: "web-\(error.code)")
    }
}
