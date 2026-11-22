import XCTest
import WebKit
@testable import CodexAppMobile

final class ChatGPTWebTests: XCTestCase {
    @MainActor
    func testTwoProfileSwitchKeepsDistinctWebViewsAndSelectionAcrossLaunch() throws {
        let suite = "ChatGPTWebProfiles.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ChatGPTWebViewModel(storeIdentifier: UUID(), initialURL: URL(string: "about:blank")!)
        let second = ChatGPTWebViewModel(storeIdentifier: UUID(), initialURL: URL(string: "about:blank")!)
        let profiles = ChatGPTWebProfiles(defaults: defaults, first: first, second: second)
        XCTAssertEqual(profiles.selected, .first)
        let firstView = first.prepareWebView()
        let secondView = second.prepareWebView()
        XCTAssertFalse(firstView === secondView)
        XCTAssertFalse(firstView.configuration.websiteDataStore === secondView.configuration.websiteDataStore)
        profiles.select(.second)
        XCTAssertTrue(profiles.active === second)
        XCTAssertTrue(profiles.active.webView === secondView)
        XCTAssertNil(firstView.url)
        profiles.select(.first)
        XCTAssertTrue(profiles.active.webView === firstView)
        let relaunched = ChatGPTWebProfiles(defaults: defaults, first: first, second: second)
        XCTAssertEqual(relaunched.selected, .first)
        profiles.select(.second)
        XCTAssertEqual(ChatGPTWebProfiles(defaults: defaults, first: first, second: second).selected, .second)
    }

    @MainActor
    func testTwoProfilesRetainDistinctSessionsAndScopedResetAcrossRestart() async throws {
        let firstID = UUID(), secondID = UUID()
        let first = ChatGPTWebViewModel(storeIdentifier: firstID)
        let second = ChatGPTWebViewModel(storeIdentifier: secondID)
        let firstCookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "chatgpt.com", .path: "/", .name: "session-test", .value: "web-account-a",
            .secure: "TRUE", .expires: Date().addingTimeInterval(600)
        ]))
        let secondCookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "chatgpt.com", .path: "/", .name: "session-test", .value: "web-account-b",
            .secure: "TRUE", .expires: Date().addingTimeInterval(600)
        ]))
        await first.dataStore.httpCookieStore.setCookie(firstCookie)
        await second.dataStore.httpCookieStore.setCookie(secondCookie)
        let reconstructedA = ChatGPTWebViewModel(storeIdentifier: firstID)
        let reconstructedB = ChatGPTWebViewModel(storeIdentifier: secondID)
        let cookiesA = await reconstructedA.dataStore.httpCookieStore.allCookies()
        let cookiesB = await reconstructedB.dataStore.httpCookieStore.allCookies()
        XCTAssertEqual(cookiesA.first(where: { $0.name == "session-test" })?.value, "web-account-a")
        XCTAssertEqual(cookiesB.first(where: { $0.name == "session-test" })?.value, "web-account-b")
        await first.clearWebsiteData()
        let clearedA = await reconstructedA.dataStore.httpCookieStore.allCookies()
        let retainedB = await reconstructedB.dataStore.httpCookieStore.allCookies()
        XCTAssertFalse(clearedA.contains(where: { $0.name == "session-test" }))
        XCTAssertEqual(retainedB.first(where: { $0.name == "session-test" })?.value, "web-account-b")
        await second.clearWebsiteData()
    }

    func testNavigationAllowsOfficialSitesAndAuthenticationProviders() {
        for address in [
            "https://chatgpt.com/c/test", "https://auth.openai.com/login",
            "https://accounts.google.com/o/oauth2/auth", "https://appleid.apple.com/auth/authorize",
            "https://login.microsoftonline.com/common/oauth2", "https://files.oaiusercontent.com/file"
        ] {
            XCTAssertEqual(ChatGPTWebPolicy.navigation(to: URL(string: address), isMainFrame: true), .allow, address)
        }
    }

    func testNavigationRejectsInsecureCredentialsAndLookalikeDomains() {
        for address in [
            "http://chatgpt.com", "https://user:secret@chatgpt.com",
            "https://chatgpt.com:8443", "file:///etc/passwd", "javascript:alert(1)",
            "data:text/html,hello", "openai://callback?code=private"
        ] {
            XCTAssertEqual(ChatGPTWebPolicy.navigation(to: URL(string: address), isMainFrame: true), .block, address)
        }
        for address in ["https://chatgpt.com.attacker.example", "https://notopenai.com", "https://example.com"] {
            XCTAssertEqual(ChatGPTWebPolicy.navigation(to: URL(string: address), isMainFrame: true), .external, address)
        }
    }

    func testFrameAndBlobPolicies() {
        XCTAssertEqual(ChatGPTWebPolicy.navigation(to: URL(string: "https://challenges.cloudflare.com"), isMainFrame: false), .allow)
        XCTAssertEqual(ChatGPTWebPolicy.navigation(to: URL(string: "http://challenges.cloudflare.com"), isMainFrame: false), .block)
        XCTAssertEqual(ChatGPTWebPolicy.navigation(to: URL(string: "about:blank"), isMainFrame: true), .allow)
        XCTAssertEqual(ChatGPTWebPolicy.navigation(to: URL(string: "blob:https://chatgpt.com/uuid"), isMainFrame: true), .allow)
        XCTAssertEqual(ChatGPTWebPolicy.navigation(to: URL(string: "blob:https://example.com/uuid"), isMainFrame: true), .block)
    }

    func testMediaOnlyPromptsForChatGPTSecureOrigin() {
        XCTAssertTrue(ChatGPTWebPolicy.allowsMedia(scheme: "https", host: "chatgpt.com", port: 443))
        XCTAssertTrue(ChatGPTWebPolicy.allowsMedia(scheme: "https", host: "chatgpt.com", port: 0))
        XCTAssertFalse(ChatGPTWebPolicy.allowsMedia(scheme: "http", host: "chatgpt.com", port: 80))
        XCTAssertFalse(ChatGPTWebPolicy.allowsMedia(scheme: "https", host: "chatgpt.com.evil.test", port: 443))
        XCTAssertFalse(ChatGPTWebPolicy.allowsMedia(scheme: "https", host: "accounts.google.com", port: 443))
    }

    func testNavigationErrorsNeverRevealOAuthURLsOrDescriptions() throws {
        let secret = "https://auth.openai.com/callback?code=secret-value&state=private"
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLStringErrorKey: secret
        ])
        let safe = try XCTUnwrap(ChatGPTWebFailure.navigation(error))
        XCTAssertEqual(safe.code, "timeout")
        XCTAssertFalse(safe.message.contains("secret-value"))
        XCTAssertFalse(safe.message.contains("state="))
        XCTAssertNil(ChatGPTWebFailure.navigation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
    }

    func testDownloadNamesStayInsideDestinationDirectory() {
        XCTAssertEqual(ChatGPTWebPolicy.safeFilename("../../private/report.pdf"), "report.pdf")
        XCTAssertEqual(ChatGPTWebPolicy.safeFilename("C:\\temp\\report.pdf"), "report.pdf")
        XCTAssertEqual(ChatGPTWebPolicy.safeFilename(".."), "download")
        XCTAssertEqual(ChatGPTWebPolicy.safeFilename("\u{0}file\n.txt"), "file.txt")
        let unicodeName = ChatGPTWebPolicy.safeFilename(String(repeating: "🧪", count: 100) + ".txt")
        XCTAssertLessThanOrEqual(unicodeName.utf8.count, 180)
    }

    @MainActor
    func testWebViewIsLazyStableAndUsesDedicatedPersistentStorage() {
        let identifier = UUID()
        let model = ChatGPTWebViewModel(storeIdentifier: identifier)
        XCTAssertNil(model.webView)
        let first = model.prepareWebView()
        let second = model.prepareWebView()
        XCTAssertTrue(first === second)
        XCTAssertNil(first.url, "Creating or reusing the view must not start network navigation.")
        XCTAssertTrue(first.customUserAgent?.isEmpty ?? true,
                      "Do not impersonate Safari to bypass embedded-browser restrictions.")
        XCTAssertTrue(first.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(first.configuration.websiteDataStore.identifier, identifier)
        XCTAssertNotEqual(identifier, WKWebsiteDataStore.default().identifier)
        XCTAssertTrue(first.configuration.userContentController.userScripts.isEmpty)
    }

    @MainActor
    func testCookiePersistenceAndScopedClearLeaveOtherStateUntouched() async throws {
        let identifier = UUID()
        let otherIdentifier = UUID()
        let model = ChatGPTWebViewModel(storeIdentifier: identifier)
        let reconstructedModel = ChatGPTWebViewModel(storeIdentifier: identifier)
        let otherStore = WKWebsiteDataStore(forIdentifier: otherIdentifier)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "chatgpt.com", .path: "/", .name: "test-session", .value: "isolated",
            .secure: "TRUE", .expires: Date().addingTimeInterval(600)
        ]))
        let otherCookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "chatgpt.com", .path: "/", .name: "test-session", .value: "other-profile",
            .secure: "TRUE", .expires: Date().addingTimeInterval(600)
        ]))
        let credentials = InMemoryHostCredentialStore()
        let hostID = UUID()
        credentials.save(password: "codex-connection-placeholder", for: hostID)
        let suiteName = "ChatGPTWebTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("preserved", forKey: "codex.host.sentinel")

        await model.dataStore.httpCookieStore.setCookie(cookie)
        await otherStore.httpCookieStore.setCookie(otherCookie)
        let persisted = await reconstructedModel.dataStore.httpCookieStore.allCookies()
        XCTAssertEqual(persisted.first(where: { $0.name == "test-session" })?.value, "isolated")

        await model.clearWebsiteData()
        let cleared = await reconstructedModel.dataStore.httpCookieStore.allCookies()
        let untouched = await otherStore.httpCookieStore.allCookies()
        XCTAssertFalse(cleared.contains(where: { $0.name == "test-session" }))
        XCTAssertEqual(untouched.first(where: { $0.name == "test-session" })?.value, "other-profile")
        XCTAssertEqual(credentials.readPassword(for: hostID), "codex-connection-placeholder")
        XCTAssertEqual(defaults.string(forKey: "codex.host.sentinel"), "preserved")
        XCTAssertFalse(model.isClearing)
        XCTAssertNil(model.webView)
        await otherStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    @MainActor
    func testResetBlanksExistingPageAndDoesNotRaceRepeatedRequests() async {
        let model = ChatGPTWebViewModel(storeIdentifier: UUID())
        let original = model.prepareWebView()
        let firstReset = Task { await model.clearWebsiteData() }
        await Task.yield()
        await model.clearWebsiteData()
        await firstReset.value
        XCTAssertNil(model.failure)
        XCTAssertFalse(model.isClearing)
        XCTAssertNil(model.webView)
        XCTAssertFalse(original.isUserInteractionEnabled)
        XCTAssertFalse(original.isLoading)
        XCTAssertEqual(original.url?.absoluteString, "about:blank")
        XCTAssertFalse(model.prepareWebView() === original)
    }

    @MainActor
    func testDismissedPageCallbacksCannotReplaceCurrentBrowserStatus() {
        let model = ChatGPTWebViewModel(storeIdentifier: UUID())
        let active = model.prepareWebView()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = model.dataStore
        let discarded = WKWebView(frame: .zero, configuration: configuration)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        model.webView(discarded, didFail: nil, withError: error)
        XCTAssertNil(model.failure)
        model.webView(active, didFail: nil, withError: error)
        XCTAssertEqual(model.failure?.code, "timeout")
        model.webView(discarded, didCommit: nil)
        model.webView(active, didStartProvisionalNavigation: nil)
        XCTAssertEqual(model.failure?.code, "timeout")
        model.webView(active, didCommit: nil)
        XCTAssertNil(model.failure)
    }

    @MainActor
    func testJavaScriptDialogRepliesOnlyOnceWhenResetAndUserActionRace() {
        var results: [String?] = []
        let reply = ChatGPTDialogReply { results.append($0) }
        reply.resolve(nil)
        reply.resolve("late-button-action")
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0])
    }

    @MainActor
    func testDownloadWaitsForPopupDismissalAndRemovesTemporaryFileAfterSharing() async throws {
        let model = ChatGPTWebViewModel(storeIdentifier: UUID())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = model.dataStore
        let popup = WKWebView(frame: .zero, configuration: configuration)
        model.presentPopup(popup)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("report.txt")
        try Data("download test".utf8).write(to: file)
        model.downloadDirectory = directory
        model.downloadDestination = file
        model.downloadFinished()

        guard case .popup? = model.sheet else { return XCTFail("The popup must remain visible while the download waits.") }
        model.dismissSheet()
        model.presentReadyDownload()
        XCTAssertNil(model.sheet, "Do not present a second sheet during the first dismissal animation.")
        model.sheetDidDismiss()
        guard case .download(let downloaded)? = model.sheet else { return XCTFail("The finished file should now be shareable.") }
        XCTAssertEqual(downloaded.url, file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        model.dismissSheet()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(model.readyDownload)
        model.sheetDidDismiss()
        await model.clearWebsiteData()
        XCTAssertNil(model.failure)
    }
}
