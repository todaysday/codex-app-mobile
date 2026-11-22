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


// Profile records contain only user-visible labels and stable WebKit identifiers.
// Authentication data remains exclusively in the isolated named WKWebsiteDataStores.
@MainActor
final class ChatGPTWebProfiles: ObservableObject {
    struct Profile: Codable, Equatable, Identifiable {
        let id: UUID
        var name: String
    }

    static let defaultProfile = Profile(id: ChatGPTWebPolicy.storeIdentifier, name: "Web 1")
    private static let profilesKey = "chatgpt.web.profiles.v2"
    private static let selectionKey = "chatgpt.web.selectedProfileID.v2"
    private static let legacySelectionKey = "chatgpt.web.selectedProfile.v1"

    @Published private(set) var profiles: [Profile]
    @Published private(set) var selectedID: UUID
    @Published private(set) var isRemovingProfile = false
    @Published var managementError: String?

    private let defaults: UserDefaults
    private var models: [UUID: ChatGPTWebViewModel] = [:]

    init(defaults: UserDefaults = .standard, first: ChatGPTWebViewModel? = nil) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Self.profilesKey),
           let stored = try? JSONDecoder().decode([Profile].self, from: data),
           !stored.isEmpty,
           Set(stored.map(\.id)).count == stored.count,
           stored.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            profiles = stored
        } else if let oldSelection = defaults.string(forKey: Self.legacySelectionKey) {
            // A pre-release two-profile installation may have WebKit data in the
            // earlier fixed secondary ID. Retain both only when that version ran.
            profiles = [
                Self.defaultProfile,
                Profile(id: ChatGPTWebPolicy.secondaryStoreIdentifier, name: "Web 2")
            ]
            selectedID = oldSelection == "second"
                ? ChatGPTWebPolicy.secondaryStoreIdentifier : ChatGPTWebPolicy.storeIdentifier
        } else {
            profiles = [Self.defaultProfile]
        }

        let requested = UUID(uuidString: defaults.string(forKey: Self.selectionKey) ?? "")
        selectedID = requested.flatMap { id in
            profiles.contains(where: { $0.id == id }) ? id : nil
        } ?? (defaults.string(forKey: Self.legacySelectionKey) == "second"
              && profiles.contains(where: { $0.id == ChatGPTWebPolicy.secondaryStoreIdentifier })
              ? ChatGPTWebPolicy.secondaryStoreIdentifier : profiles[0].id)

        if let first, profiles.contains(where: { $0.id == Self.defaultProfile.id }) {
            models[Self.defaultProfile.id] = first
        }
        if models[selectedID] == nil {
            models[selectedID] = ChatGPTWebViewModel(storeIdentifier: selectedID)
        }
    }

    var selectedName: String {
        profiles.first(where: { $0.id == selectedID })?.name ?? "ChatGPT"
    }

    var active: ChatGPTWebViewModel {
        model(for: selectedID)
    }

    func profile(id: UUID) -> Profile? {
        profiles.first(where: { $0.id == id })
    }

    func model(for id: UUID) -> ChatGPTWebViewModel {
        if let existing = models[id] { return existing }
        let created = ChatGPTWebViewModel(storeIdentifier: id)
        models[id] = created
        return created
    }

    func select(_ id: UUID) {
        guard !isRemovingProfile, profiles.contains(where: { $0.id == id }), selectedID != id else { return }
        _ = model(for: id)
        selectedID = id
        defaults.set(id.uuidString, forKey: Self.selectionKey)
        // Switches never navigate, clear cookies or log out other profiles.
    }

    @discardableResult
    func addProfile(name: String = "") -> Profile {
        let rawName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var serial = 2
        while profiles.contains(where: { $0.name.caseInsensitiveCompare("Web \(serial)") == .orderedSame }) {
            serial += 1
        }
        let newProfile = Profile(id: UUID(), name: rawName.isEmpty ? "Web \(serial)" : String(rawName.prefix(80)))
        profiles.append(newProfile)
        _ = model(for: newProfile.id)
        persist()
        select(newProfile.id)
        managementError = nil
        return newProfile
    }

    @discardableResult
    func renameProfile(id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = profiles.firstIndex(where: { $0.id == id }), !trimmed.isEmpty else {
            managementError = "Enter a name for the web profile."
            return false
        }
        profiles[index].name = String(trimmed.prefix(80))
        persist()
        managementError = nil
        return true
    }

    /// Permanent removal is allowed only when another profile can remain.
    /// A failed WebKit store removal keeps the saved profile for an explicit retry.
    @discardableResult
    func removeProfile(id: UUID) async -> Bool {
        guard !isRemovingProfile else { return false }
        guard profiles.count > 1, profiles.contains(where: { $0.id == id }) else {
            managementError = "The last web profile cannot be deleted. Clear its data instead."
            return false
        }
        isRemovingProfile = true
        defer { isRemovingProfile = false }
        managementError = nil

        let model = model(for: id)
        await model.clearWebsiteData()
        guard !model.isClearing, model.failure == nil, model.webView == nil else {
            managementError = "Could not stop the profile page. Its data was not deleted; try again."
            return false
        }

        // Unmount a selected profile and release its browser before WebKit removes
        // its named data store. All other models and stores remain untouched.
        if selectedID == id, let replacement = profiles.first(where: { $0.id != id }) {
            selectedID = replacement.id
            _ = model(for: replacement.id)
            defaults.set(replacement.id.uuidString, forKey: Self.selectionKey)
        }
        models.removeValue(forKey: id)
        await Task.yield()
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: id)
        } catch {
            managementError = "The page data was cleared, but WebKit could not remove this profile's storage. Try deleting it again."
            return false
        }
        profiles.removeAll(where: { $0.id == id })
        persist()
        return true
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Self.profilesKey)
        defaults.set(selectedID.uuidString, forKey: Self.selectionKey)
    }
}
