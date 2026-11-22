import Combine
import Foundation
import UIKit
@preconcurrency import WebKit

@MainActor
final class ChatGPTWebViewModel: NSObject, ObservableObject {
    @Published private(set) var webView: WKWebView?
    @Published private(set) var isLoading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var currentHost = "chatgpt.com"
    @Published private(set) var isClearing = false
    @Published var failure: ChatGPTWebFailure?
    @Published private(set) var sheet: ChatGPTWebSheet?
    @Published private(set) var readyDownload: ChatGPTDownloadedFile?
    @Published private(set) var isDownloading = false

    let dataStore: WKWebsiteDataStore
    var activeDialog: UIAlertController?
    var cancelDialog: (@MainActor () -> Void)?
    var download: WKDownload?
    var downloadDestination: URL?
    var downloadDirectory: URL?
    private var observations: [NSKeyValueObservation] = []
    private var didStart = false
    private let initialURL: URL
    private var closingPopup: WKWebView?
    private var popupClosingTask: Task<Bool, Never>?
    private var awaitsSheetDismissal = false

    init(storeIdentifier: UUID = ChatGPTWebPolicy.storeIdentifier, initialURL: URL = ChatGPTWebPolicy.homeURL) {
        dataStore = WKWebsiteDataStore(forIdentifier: storeIdentifier)
        self.initialURL = initialURL
        super.init()
    }

    /// Creates the view without making a network request; useful for lifecycle tests too.
    @discardableResult
    func prepareWebView() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        view.scrollView.backgroundColor = .systemBackground
        webView = view
        observe(view)
        return view
    }

    func loadIfNeeded() {
        guard !isClearing, !didStart else { return }
        didStart = true
        prepareWebView().load(URLRequest(url: initialURL))
    }

    func reload() {
        guard !isClearing else { return }
        failure = nil
        if let webView, didStart, let url = webView.url, url.absoluteString != "about:blank" {
            webView.reload()
        } else {
            goHome()
        }
    }

    func goHome() {
        guard !isClearing else { return }
        failure = nil
        didStart = true
        prepareWebView().load(URLRequest(url: initialURL))
    }

    func goBack() { if !isClearing { webView?.goBack() } }
    func goForward() { if !isClearing { webView?.goForward() } }

    func openBrowser() {
        presentBrowser(url: ChatGPTWebPolicy.homeURL)
    }

    func presentBrowser(url: URL) {
        guard !isClearing, !awaitsSheetDismissal, sheet == nil, ChatGPTWebPolicy.isSecureURL(url) else { return }
        sheet = .browser(url)
    }

    var canPresentPopup: Bool { !isClearing && !awaitsSheetDismissal && sheet == nil && closingPopup == nil }

    func presentPopup(_ view: WKWebView) {
        guard canPresentPopup else { return }
        sheet = .popup(ChatGPTWebPopup(webView: view))
    }

    func owns(_ view: WKWebView) -> Bool {
        if webView === view { return true }
        if case .popup(let popup)? = sheet { return popup.webView === view }
        return false
    }

    func dismissSheet() {
        guard let previous = sheet else { return }
        awaitsSheetDismissal = true
        sheet = nil
        if case .popup(let popup) = previous {
            closePopup(popup.webView)
        }
        if case .download(let file) = previous {
            try? FileManager.default.removeItem(at: file.directory)
            if readyDownload?.id == file.id { readyDownload = nil }
        }
    }

    func sheetDidDismiss() {
        awaitsSheetDismissal = false
        presentReadyDownload()
    }

    private func closePopup(_ view: WKWebView) {
        closingPopup = view
        let task = Task { @MainActor in await ChatGPTPageQuiescer().blank(view) }
        popupClosingTask = task
        Task { @MainActor [weak self] in
            let stopped = await task.value
            guard let self, self.closingPopup === view else { return }
            self.popupClosingTask = nil
            if stopped { self.closingPopup = nil }
            // A page that failed to stop stays retained for the next explicit reset.
        }
    }

    func presentReadyDownload() {
        guard !isClearing, !awaitsSheetDismissal, sheet == nil, let readyDownload else { return }
        sheet = .download(readyDownload)
    }

    func dismissJavaScriptDialog() {
        let cancellation = cancelDialog
        cancelDialog = nil
        activeDialog?.dismiss(animated: false)
        activeDialog = nil
        cancellation?()
    }

    /// The caller presents confirmation first. Repeated calls during a reset are ignored.
    func clearWebsiteData() async {
        guard !isClearing else { return }
        isClearing = true
        failure = nil
        dismissJavaScriptDialog()
        cancelDownload()
        var views = webView.map { [$0] } ?? []
        if case .popup(let popup)? = sheet { views.append(popup.webView) }
        if sheet != nil { awaitsSheetDismissal = true }
        sheet = nil
        if let closingPopup {
            if let popupClosingTask { _ = await popupClosingTask.value }
            views.append(closingPopup)
        }
        // A loaded document can keep writing cookies after stopLoading(). Blank every
        // document and wait for navigation to finish before removing its store data.
        var failedViews: [WKWebView] = []
        for view in views {
            if !(await ChatGPTPageQuiescer().blank(view)) { failedViews.append(view) }
        }
        if !failedViews.isEmpty {
            if let webView {
                webView.navigationDelegate = self
                webView.uiDelegate = self
                webView.isUserInteractionEnabled = true
            }
            closingPopup = failedViews.first(where: { $0 !== webView })
            popupClosingTask = nil
            failure = .init(message: "The web page could not be stopped. Reload it and try clearing again.", code: "clear-timeout")
            didStart = true
            isClearing = false
            return
        }
        observations.removeAll()
        webView = nil
        closingPopup = nil
        popupClosingTask = nil
        didStart = false
        if let readyDownload { try? FileManager.default.removeItem(at: readyDownload.directory) }
        readyDownload = nil
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        refreshNavigationState()
        isClearing = false
        // Remain unloaded after reset; the screen loads a fresh page when visible.
    }

    func refreshNavigationState() {
        isLoading = webView?.isLoading ?? false
        progress = webView?.estimatedProgress ?? 0
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
        currentHost = webView?.url?.host ?? "chatgpt.com"
    }

    func record(_ error: Error) {
        if let safeFailure = ChatGPTWebFailure.navigation(error) { failure = safeFailure }
        refreshNavigationState()
    }

    private func observe(_ view: WKWebView) {
        observations = [
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshNavigationState() }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshNavigationState() }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshNavigationState() }
            },
            view.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshNavigationState() }
            },
            view.observe(\.url, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshNavigationState() }
            }
        ]
    }

    func downloadStarted(_ newDownload: WKDownload) {
        guard !isClearing, download == nil, readyDownload == nil else {
            newDownload.cancel { _ in }
            failure = .init(message: "Finish or dismiss the current download before starting another.", code: "download-busy")
            return
        }
        download = newDownload
        isDownloading = true
        newDownload.delegate = self
    }

    func downloadFinished() {
        if let url = downloadDestination, let directory = downloadDirectory {
            readyDownload = ChatGPTDownloadedFile(url: url, directory: directory)
        }
        download?.delegate = nil
        download = nil
        downloadDestination = nil
        downloadDirectory = nil
        isDownloading = false
        presentReadyDownload()
    }

    func cancelDownload() {
        download?.delegate = nil
        download?.cancel { _ in }
        download = nil
        if let downloadDirectory { try? FileManager.default.removeItem(at: downloadDirectory) }
        downloadDirectory = nil
        downloadDestination = nil
        isDownloading = false
    }
}

struct ChatGPTWebPopup: Identifiable {
    let id = UUID()
    let webView: WKWebView
}

struct ChatGPTDownloadedFile: Identifiable {
    let id = UUID()
    let url: URL
    let directory: URL
}

enum ChatGPTWebSheet: Identifiable {
    case popup(ChatGPTWebPopup)
    case browser(URL)
    case download(ChatGPTDownloadedFile)

    var id: String {
        switch self {
        case .popup(let popup): return popup.id.uuidString
        case .browser: return "browser"
        case .download(let file): return file.id.uuidString
        }
    }
}


// The two user-selectable website profiles deliberately have no shared cookie store.
// Only the profile selection is saved in preferences; auth cookies stay in WebKit.
@MainActor
final class ChatGPTWebProfiles: ObservableObject {
    enum Slot: String, CaseIterable, Identifiable {
        case first, second
        var id: String { rawValue }
        var title: String { self == .first ? "Web 1" : "Web 2" }
    }

    @Published private(set) var selected: Slot
    let first: ChatGPTWebViewModel
    let second: ChatGPTWebViewModel
    private let defaults: UserDefaults
    private let selectionKey = "chatgpt.web.selectedProfile.v1"

    init(defaults: UserDefaults = .standard,
         first: ChatGPTWebViewModel? = nil,
         second: ChatGPTWebViewModel? = nil) {
        self.defaults = defaults
        self.first = first ?? ChatGPTWebViewModel(storeIdentifier: ChatGPTWebPolicy.storeIdentifier)
        self.second = second ?? ChatGPTWebViewModel(storeIdentifier: ChatGPTWebPolicy.secondaryStoreIdentifier)
        selected = Slot(rawValue: defaults.string(forKey: selectionKey) ?? "") ?? .first
    }

    var active: ChatGPTWebViewModel { model(for: selected) }

    func model(for slot: Slot) -> ChatGPTWebViewModel {
        slot == .first ? first : second
    }

    func select(_ slot: Slot) {
        guard selected != slot else { return }
        selected = slot
        defaults.set(slot.rawValue, forKey: selectionKey)
        // No clearing, network navigation, or authentication action on selection.
    }
}
