import UIKit
import WebKit
import XCTest
@testable import CodexAppMobile

final class ChatGPTWebProfileTests: XCTestCase {
    @MainActor
    func testInitialRegistryMigratesThePreviouslyShippedWebsiteStore() throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ChatGPTWebProfiles(defaults: defaults)
        XCTAssertEqual(profiles.profiles.count, 1)
        XCTAssertEqual(profiles.selectedProfile.id, UUID(uuidString: "70E5ABF8-5C6B-4E75-A7F1-FF38825C26D3"))
        XCTAssertEqual(profiles.selectedProfile.id, ChatGPTWebPolicy.storeIdentifier)
        XCTAssertEqual(profiles.selectedProfile.name, "Account 1")
        XCTAssertNotNil(defaults.data(forKey: ChatGPTWebProfiles.registryDefaultsKey))
    }

    @MainActor
    func testSettingsCanAddMoreThanTwoProfilesAndRestoreTheirNamesAndSelection() throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ChatGPTWebProfile(id: UUID(), name: "Personal")
        let profiles = ChatGPTWebProfiles(defaults: defaults, initialProfile: first)
        _ = try profiles.addProfile(named: "Work")
        _ = try profiles.addProfile(named: "Research")
        let fourth = try profiles.addProfile(named: "Another account")
        XCTAssertEqual(profiles.profiles.count, 4)
        XCTAssertEqual(Set(profiles.profiles.map(\.id)).count, 4)
        XCTAssertEqual(profiles.selectedProfileID, fourth.id)
        XCTAssertTrue(profiles.select(first.id))
        for profile in profiles.profiles {
            XCTAssertNil(profiles.model(for: profile.id)?.webView, "Settings actions must not create or navigate WKWebViews.")
        }

        let restored = ChatGPTWebProfiles(defaults: defaults, initialProfile: first)
        XCTAssertEqual(restored.profiles, profiles.profiles)
        XCTAssertEqual(restored.selectedProfileID, first.id)
        XCTAssertNil(restored.selectedModel.webView)
    }

    @MainActor
    func testInvalidSavedSelectionFallsBackWithoutReplacingProfiles() throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ChatGPTWebProfile(id: UUID(), name: "Personal")
        let profiles = ChatGPTWebProfiles(defaults: defaults, initialProfile: first)
        _ = try profiles.addProfile(named: "Work")
        _ = try profiles.addProfile(named: "Research")
        let data = try XCTUnwrap(defaults.data(forKey: ChatGPTWebProfiles.registryDefaultsKey))
        var registry = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        registry["selectedProfileID"] = UUID().uuidString
        defaults.set(try JSONSerialization.data(withJSONObject: registry), forKey: ChatGPTWebProfiles.registryDefaultsKey)

        let restored = ChatGPTWebProfiles(defaults: defaults, initialProfile: first)
        XCTAssertEqual(restored.profiles, profiles.profiles)
        XCTAssertEqual(restored.selectedProfileID, first.id)
    }

    @MainActor
    func testRenameKeepsSessionAndBrowserWhileInvalidNamesLeaveRegistryUntouched() async throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ChatGPTWebProfile(id: UUID(), name: "Personal")
        let profiles = ChatGPTWebProfiles(defaults: defaults, initialProfile: first)
        let model = profiles.selectedModel
        let originalView = try XCTUnwrap(model.prepareWebView())
        await model.dataStore.httpCookieStore.setCookie(try sessionCookie("retained-account"))
        _ = try profiles.addProfile(named: "Work")
        try profiles.renameProfile(id: first.id, to: "  Private  ")
        XCTAssertEqual(profiles.profiles.first?.name, "Private")
        XCTAssertTrue(profiles.model(for: first.id)?.webView === originalView)
        let session = await sessionValue(in: model)
        XCTAssertEqual(session, "retained-account")

        let beforeInvalidChanges = profiles.profiles
        for name in [" ", "work", "bad\nname", "bad\u{2028}name", "bad\u{2029}name", String(repeating: "x", count: 61)] {
            XCTAssertThrowsError(try profiles.addProfile(named: name))
            XCTAssertThrowsError(try profiles.renameProfile(id: first.id, to: name))
        }
        XCTAssertEqual(profiles.profiles, beforeInvalidChanges)
        let restored = ChatGPTWebProfiles(defaults: defaults, initialProfile: first)
        XCTAssertEqual(restored.profiles, profiles.profiles)
        XCTAssertEqual(restored.profiles.first?.id, first.id)
        let restoredSession = await sessionValue(in: try XCTUnwrap(restored.model(for: first.id)))
        XCTAssertEqual(restoredSession, "retained-account")
        await clearAll(profiles)
    }

    @MainActor
    func testThreeSameOriginSessionFixturesSurviveSwitchingAndRegistryReconstruction() async throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = try threeProfiles(defaults: defaults)
        var views: [UUID: WKWebView] = [:]
        for (index, profile) in profiles.profiles.enumerated() {
            let model = try XCTUnwrap(profiles.model(for: profile.id))
            views[profile.id] = try XCTUnwrap(model.prepareWebView())
            await model.dataStore.httpCookieStore.setCookie(try sessionCookie("fixture-account-\(index)"))
        }
        for (index, profile) in profiles.profiles.enumerated() {
            XCTAssertTrue(profiles.select(profile.id))
            XCTAssertTrue(profiles.selectedModel.webView === views[profile.id])
            let value = await sessionValue(in: profiles.selectedModel)
            XCTAssertEqual(value, "fixture-account-\(index)")
            XCTAssertNil(profiles.selectedModel.webView?.url, "Selection alone must not navigate a retained browser.")
        }
        let restored = ChatGPTWebProfiles(defaults: defaults)
        XCTAssertEqual(restored.profiles, profiles.profiles)
        XCTAssertEqual(restored.selectedProfileID, profiles.selectedProfileID)
        for (index, profile) in restored.profiles.enumerated() {
            let model = try XCTUnwrap(restored.model(for: profile.id))
            let value = await sessionValue(in: model)
            XCTAssertEqual(value, "fixture-account-\(index)")
            XCTAssertNil(model.webView)
        }
        await clearAll(profiles)
    }

    @MainActor
    func testClearingOneOfThreeProfilesPreservesOtherSessionsAndRetainedBrowsers() async throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unchanged", forKey: "codex.host.sentinel")
        let profiles = try threeProfiles(defaults: defaults)
        var views: [UUID: WKWebView] = [:]
        for profile in profiles.profiles {
            let model = try XCTUnwrap(profiles.model(for: profile.id))
            views[profile.id] = try XCTUnwrap(model.prepareWebView())
            await model.dataStore.httpCookieStore.setCookie(try sessionCookie(profile.name))
        }
        let target = profiles.profiles[1]
        XCTAssertTrue(profiles.select(target.id))
        let targetView = try XCTUnwrap(views[target.id])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(targetView)
        window.makeKeyAndVisible()
        targetView.frame = controller.view.bounds
        targetView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.layoutIfNeeded()
        defer {
            targetView.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        // Exercise clearing an existing document. A zero-frame, never-loaded WKWebView
        // would spend the quiescer's timeout starting WebContent/GPU processes in CI.
        try await ProfileFixturePageLoader().load(in: targetView)
        XCTAssertEqual(targetView.title, "Profile clear fixture")
        XCTAssertTrue(targetView.window === window)
        let didClear = await profiles.selectedModel.clearWebsiteData()
        XCTAssertTrue(didClear)
        XCTAssertEqual(profiles.profiles.count, 3, "Clearing data keeps the profile registration.")
        for profile in profiles.profiles {
            let model = try XCTUnwrap(profiles.model(for: profile.id))
            let value = await sessionValue(in: model)
            if profile.id == target.id {
                XCTAssertNil(value)
                XCTAssertNil(model.webView)
                XCTAssertFalse(try XCTUnwrap(views[profile.id]).isUserInteractionEnabled)
            } else {
                XCTAssertEqual(value, profile.name)
                XCTAssertTrue(model.webView === views[profile.id])
            }
        }
        XCTAssertEqual(defaults.string(forKey: "codex.host.sentinel"), "unchanged")
        await clearAll(profiles)
    }

    @MainActor
    func testDeletingInactiveProfileClearsOnlyItsStoreAndKeepsCurrentSelection() async throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = try threeProfiles(defaults: defaults)
        let removed = profiles.profiles[1]
        let removedModel = try XCTUnwrap(profiles.model(for: removed.id))
        let selected = profiles.selectedProfile
        let selectedView = try XCTUnwrap(profiles.selectedModel.prepareWebView())
        for profile in profiles.profiles {
            let model = try XCTUnwrap(profiles.model(for: profile.id))
            await model.dataStore.httpCookieStore.setCookie(try sessionCookie(profile.name))
        }

        try await profiles.deleteProfile(id: removed.id)
        XCTAssertFalse(profiles.isDeleting)
        XCTAssertEqual(profiles.profiles.count, 2)
        XCTAssertNil(profiles.model(for: removed.id))
        XCTAssertEqual(profiles.selectedProfileID, selected.id)
        XCTAssertTrue(profiles.selectedModel.webView === selectedView)
        let removedSession = await sessionValue(in: removedModel)
        XCTAssertNil(removedSession)
        XCTAssertTrue(removedModel.isRetired)
        removedModel.loadIfNeeded()
        removedModel.goHome()
        removedModel.reload()
        removedModel.openBrowser()
        XCTAssertNil(removedModel.prepareWebView(), "A late screen task cannot recreate a deleted profile's page.")
        XCTAssertNil(removedModel.webView)
        XCTAssertNil(removedModel.sheet)
        for profile in profiles.profiles {
            let value = await sessionValue(in: try XCTUnwrap(profiles.model(for: profile.id)))
            XCTAssertEqual(value, profile.name)
        }
        let restored = ChatGPTWebProfiles(defaults: defaults)
        XCTAssertEqual(restored.profiles, profiles.profiles)
        XCTAssertEqual(restored.selectedProfileID, selected.id)
        await clearAll(profiles)
    }

    @MainActor
    func testDeletingSelectedProfileChoosesExistingProfileAndReaddingUsesFreshStore() async throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = try threeProfiles(defaults: defaults)
        let first = profiles.profiles[0]
        let firstModel = try XCTUnwrap(profiles.model(for: first.id))
        let firstView = try XCTUnwrap(firstModel.prepareWebView())
        let removed = profiles.selectedProfile
        let removedModel = profiles.selectedModel
        await firstModel.dataStore.httpCookieStore.setCookie(try sessionCookie("surviving-account"))
        await removedModel.dataStore.httpCookieStore.setCookie(try sessionCookie("removed-account"))
        try await profiles.deleteProfile(id: removed.id)
        XCTAssertEqual(profiles.selectedProfileID, first.id)
        XCTAssertTrue(profiles.selectedModel.webView === firstView)
        let survivor = await sessionValue(in: profiles.selectedModel)
        let removedSession = await sessionValue(in: removedModel)
        XCTAssertEqual(survivor, "surviving-account")
        XCTAssertNil(removedSession)

        let replacement = try profiles.addProfile(named: removed.name)
        XCTAssertNotEqual(replacement.id, removed.id)
        let replacementSession = await sessionValue(in: profiles.selectedModel)
        XCTAssertNil(replacementSession)
        let restored = ChatGPTWebProfiles(defaults: defaults)
        XCTAssertEqual(restored.selectedProfileID, replacement.id)
        XCTAssertEqual(restored.profiles, profiles.profiles)
        await clearAll(profiles)
    }

    @MainActor
    func testLastProfileCannotBeDeletedButItsWebsiteDataCanBeCleared() async throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = ChatGPTWebProfile(id: UUID(), name: "Only account")
        let profiles = ChatGPTWebProfiles(defaults: defaults, initialProfile: initial)
        await profiles.selectedModel.dataStore.httpCookieStore.setCookie(try sessionCookie("still-signed-in"))
        do {
            try await profiles.deleteProfile(id: initial.id)
            XCTFail("The last profile must remain available.")
        } catch { XCTAssertEqual(error as? ChatGPTWebProfileError, .lastProfile) }
        XCTAssertEqual(profiles.profiles, [initial])
        let session = await sessionValue(in: profiles.selectedModel)
        XCTAssertEqual(session, "still-signed-in")
        let cleared = await profiles.selectedModel.clearWebsiteData()
        XCTAssertTrue(cleared)
        XCTAssertEqual(profiles.profiles, [initial])
    }

    @MainActor
    func testSwitchingAndAddingWaitForBrowserSheetAndJavaScriptDialog() throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = try threeProfiles(defaults: defaults)
        let otherID = profiles.profiles[0].id
        let selectedID = profiles.selectedProfileID
        let selected = profiles.selectedModel
        selected.openBrowser()
        XCTAssertFalse(profiles.select(otherID))
        XCTAssertThrowsError(try profiles.addProfile(named: "Deferred account"))
        XCTAssertEqual(profiles.profiles.count, 3)
        selected.dismissSheet()
        XCTAssertFalse(profiles.select(otherID), "Dismissal animation still belongs to the original profile.")
        selected.sheetDidDismiss()
        selected.activeDialog = UIAlertController(title: "Fixture", message: nil, preferredStyle: .alert)
        XCTAssertFalse(profiles.select(otherID))
        XCTAssertEqual(profiles.selectedProfileID, selectedID)
        selected.dismissJavaScriptDialog()
        XCTAssertTrue(profiles.select(otherID))
    }

    @MainActor
    func testDeletingBusyProfileKeepsRegistrationAndSession() async throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = try threeProfiles(defaults: defaults)
        let target = profiles.profiles[0]
        let targetModel = try XCTUnwrap(profiles.model(for: target.id))
        await targetModel.dataStore.httpCookieStore.setCookie(try sessionCookie("keep-account"))
        targetModel.openBrowser()
        XCTAssertFalse(profiles.canDeleteProfile(id: target.id))
        do {
            try await profiles.deleteProfile(id: target.id)
            XCTFail("An account with a pending interaction cannot be deleted.")
        } catch { XCTAssertEqual(error as? ChatGPTWebProfileError, .busy) }
        XCTAssertTrue(profiles.profiles.contains(target))
        XCTAssertFalse(targetModel.isRetired)
        let session = await sessionValue(in: targetModel)
        XCTAssertEqual(session, "keep-account")
        targetModel.dismissSheet()
        targetModel.sheetDidDismiss()
        XCTAssertTrue(profiles.canDeleteProfile(id: target.id))
        await clearAll(profiles)
    }

    @MainActor
    func testFailedRetirementReleasesSuspensionAndCanBeRetried() async throws {
        let model = ChatGPTWebViewModel(storeIdentifier: UUID())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = model.dataStore
        let popup = RefusingProfileNavigationView(frame: .zero, configuration: configuration)
        model.presentPopup(popup)
        let failed = await model.clearWebsiteData(retiringProfile: true)
        XCTAssertFalse(failed)
        XCTAssertFalse(model.isRetired, "A failed clear must not permanently disable the retained profile.")
        XCTAssertFalse(model.isClearing)
        XCTAssertEqual(model.failure?.code, "clear-timeout")

        popup.refusesNavigation = false
        model.sheetDidDismiss()
        let recovered = await model.clearWebsiteData()
        XCTAssertTrue(recovered)
        XCTAssertNil(model.failure)
        XCTAssertFalse(model.isRetired)
        XCTAssertNotNil(model.prepareWebView())
        await model.clearWebsiteData()
    }

    @MainActor
    func testProfileSwitchWaitsForPopupQuiescence() async throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = try threeProfiles(defaults: defaults)
        let selected = profiles.selectedModel
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = selected.dataStore
        let popup = WKWebView(frame: .zero, configuration: configuration)
        selected.presentPopup(popup)
        XCTAssertFalse(profiles.select(profiles.profiles[0].id))
        selected.dismissSheet()
        selected.sheetDidDismiss()
        for _ in 0..<100 where !selected.canSwitchProfile {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(profiles.select(profiles.profiles[0].id))
        XCTAssertFalse(popup.isUserInteractionEnabled)
        await clearAll(profiles)
    }

    @MainActor
    private func threeProfiles(defaults: UserDefaults) throws -> ChatGPTWebProfiles {
        let profiles = ChatGPTWebProfiles(defaults: defaults,
                                         initialProfile: .init(id: UUID(), name: "Personal"))
        _ = try profiles.addProfile(named: "Work")
        _ = try profiles.addProfile(named: "Research")
        return profiles
    }

    private func isolatedDefaults() throws -> (String, UserDefaults) {
        let suite = "ChatGPTWebProfileTests.\(UUID().uuidString)"
        return (suite, try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    private func sessionCookie(_ value: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [
            .domain: "chatgpt.com", .path: "/", .name: "multi-profile-session-fixture", .value: value,
            .secure: "TRUE", .expires: Date().addingTimeInterval(600)
        ]))
    }

    @MainActor
    private func sessionValue(in model: ChatGPTWebViewModel) async -> String? {
        let cookies = await model.dataStore.httpCookieStore.allCookies()
        return cookies.first(where: { $0.name == "multi-profile-session-fixture" })?.value
    }

    @MainActor
    private func clearAll(_ profiles: ChatGPTWebProfiles) async {
        for profile in profiles.profiles {
            if let model = profiles.model(for: profile.id) { await model.clearWebsiteData() }
        }
    }
}

@MainActor
private final class RefusingProfileNavigationView: WKWebView {
    var refusesNavigation = true

    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        refusesNavigation ? nil : super.loadHTMLString(string, baseURL: baseURL)
    }
}

@MainActor
private final class ProfileFixturePageLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var navigation: WKNavigation?

    private enum FixtureError: Error { case couldNotStart, timedOut, processTerminated }

    func load(in webView: WKWebView) async throws {
        let previousDelegate = webView.navigationDelegate
        webView.navigationDelegate = self
        defer {
            timeout?.cancel()
            webView.navigationDelegate = previousDelegate
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                self?.finish(FixtureError.timedOut)
            }
            navigation = webView.loadHTMLString(
                "<!doctype html><title>Profile clear fixture</title><p>Local session fixture</p>",
                baseURL: ChatGPTWebPolicy.homeURL
            )
            if navigation == nil { finish(FixtureError.couldNotStart) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, navigation === self.navigation else { return }
        finish()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === self.navigation else { return }
        finish(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === self.navigation else { return }
        finish(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(FixtureError.processTerminated)
    }

    private func finish(_ error: Error? = nil) {
        timeout?.cancel()
        timeout = nil
        navigation = nil
        let pending = continuation
        continuation = nil
        if let error { pending?.resume(throwing: error) }
        else { pending?.resume() }
    }
}
