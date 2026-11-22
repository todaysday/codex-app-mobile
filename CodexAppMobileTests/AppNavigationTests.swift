import XCTest
import SwiftUI
import UIKit
@testable import CodexAppMobile

final class AppNavigationTests: XCTestCase {
    @MainActor
    func testNormalLaunchOpensCodex() {
        XCTAssertEqual(AppNavigationState().selectedTab, .codex)
    }

    @MainActor
    func testCompletionNotificationRespectsVisibleTabAndForegroundState() {
        let navigation = AppNavigationState()
        navigation.isSceneActive = true
        XCTAssertFalse(navigation.shouldNotifyCompletion(isSelectedThread: true))
        XCTAssertTrue(navigation.shouldNotifyCompletion(isSelectedThread: false))

        navigation.selectedTab = .chatGPT
        XCTAssertTrue(navigation.shouldNotifyCompletion(isSelectedThread: true))
        navigation.selectedTab = .settings
        XCTAssertTrue(navigation.shouldNotifyCompletion(isSelectedThread: true))

        navigation.selectedTab = .codex
        navigation.isSceneActive = false
        XCTAssertTrue(navigation.shouldNotifyCompletion(isSelectedThread: true))
    }

    @MainActor
    func testMountedTabRoundTripPreservesCodexSelectionAndBrowserInstance() async throws {
        let suiteName = "AppNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hosts = RemoteHostStore(defaults: defaults, credentialStore: InMemoryHostCredentialStore(),
                                    appServerCredentialStore: TestAppServerCredentialStore())
        XCTAssertTrue(hosts.upsert(hostID: nil, draft: RemoteHostDraft(
            name: "Preserved host", host: "codex.example.test", sshPort: 22, username: "tester",
            appServerHost: "", appServerPort: 443, preferredTransport: .appServerWS, password: "",
            appServerEndpoint: "wss://codex.example.test/socket"
        )))
        let hostID = try XCTUnwrap(hosts.hosts.first?.id)
        let sessions = HostSessionStore(defaults: defaults)
        let state = AppState(remoteHostStore: hosts, projectStore: ProjectStore(defaults: defaults),
                             threadBookmarkStore: ThreadBookmarkStore(defaults: defaults),
                             hostSessionStore: sessions, appServerClient: AppServerClient())
        state.selectHost(hostID)
        sessions.selectThread(hostID: hostID, threadID: "existing-thread")
        let client = state.appServerClient
        let navigation = AppNavigationState()
        let browser = ChatGPTWebViewModel(storeIdentifier: UUID(), initialURL: URL(string: "about:blank")!)
        let firstWebView = browser.prepareWebView()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: AppShellView(chatGPT: browser)
            .environmentObject(state).environmentObject(navigation))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        navigation.selectedTab = .chatGPT
        let firstMount = await waitUntil { firstWebView.isDescendant(of: window) }
        XCTAssertTrue(firstMount, "The browser must actually be mounted in the live tab hierarchy.")
        navigation.selectedTab = .settings
        await settleLayout(in: window)
        navigation.selectedTab = .codex
        await settleLayout(in: window)
        XCTAssertEqual(state.selectedHostID, hostID)
        XCTAssertEqual(sessions.session(for: hostID)?.selectedThreadID, "existing-thread")
        XCTAssertTrue(state.appServerClient === client)
        XCTAssertEqual(hosts.hosts.count, 1)

        navigation.selectedTab = .chatGPT
        let secondMount = await waitUntil { firstWebView.isDescendant(of: window) }
        XCTAssertTrue(secondMount)
        XCTAssertTrue(browser.webView === firstWebView)
        XCTAssertNil(browser.failure)
        firstWebView.stopLoading()
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @MainActor
    private func settleLayout(in window: UIWindow) async {
        await Task.yield()
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
    }
}
