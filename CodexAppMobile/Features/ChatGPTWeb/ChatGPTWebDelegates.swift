import Foundation
import UIKit
@preconcurrency import WebKit

extension ChatGPTWebViewModel: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard !isClearing, owns(webView) else { decisionHandler(.cancel); return }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        switch ChatGPTWebPolicy.navigation(to: navigationAction.request.url, isMainFrame: mainFrame) {
        case .allow:
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        case .external:
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if sheet == nil { presentBrowser(url: url) }
                else { failure = .init(message: "Close this window to open external links in the browser.", code: "external-window") }
            } else {
                failure = .init(message: "This sign-in destination needs the system browser. Open ChatGPT there to continue.", code: "external-navigation")
            }
        case .block:
            decisionHandler(.cancel)
            if mainFrame {
                failure = .init(message: "This page requested an unsupported or insecure link. Open ChatGPT in the browser if needed.", code: "blocked-navigation")
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard !isClearing, owns(webView) else { decisionHandler(.cancel); return }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !isClearing, owns(webView) else { return }
        refreshNavigationState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !isClearing, owns(webView) else { return }
        failure = nil
        refreshNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isClearing, owns(webView) else { return }
        refreshNavigationState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !isClearing, owns(webView) else { return }
        record(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isClearing, owns(webView) else { return }
        record(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isClearing, owns(webView) else { return }
        failure = .init(message: "The browser page was closed by iOS. Reload to reconnect; your saved web sign-in is retained.", code: "web-process-ended")
        refreshNavigationState()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !isClearing, owns(webView),
              ChatGPTWebPolicy.navigation(to: navigationAction.request.url, isMainFrame: true) == .allow else { return nil }
        guard canPresentPopup else {
            failure = .init(message: "Another browser window is still open or closing. Close it and try again; if it cannot close, clear ChatGPT web data.", code: "popup-busy")
            return nil
        }
        // Preserve the supplied configuration so window.opener and the WebKit session work.
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.allowsBackForwardNavigationGestures = true
        presentPopup(popup)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if case .popup(let popup)? = sheet, popup.webView === webView { dismissSheet() }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        let trusted = ChatGPTWebPolicy.allowsMedia(scheme: origin.protocol, host: origin.host, port: origin.port)
        decisionHandler(trusted && !isClearing && owns(webView) ? .prompt : .deny)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        showDialog(webView: webView, message: message, kind: .alert, defaultText: nil) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        showDialog(webView: webView, message: message, kind: .confirm, defaultText: nil) { completionHandler($0 != nil) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        showDialog(webView: webView, message: prompt, kind: .text, defaultText: defaultText, completion: completionHandler)
    }

    private enum DialogKind { case alert, confirm, text }

    private func showDialog(webView: WKWebView, message: String, kind: DialogKind,
                            defaultText: String?, completion: @escaping @MainActor (String?) -> Void) {
        guard !isClearing, owns(webView), activeDialog == nil, var presenter = webView.window?.rootViewController else {
            completion(nil)
            return
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !presenter.isBeingDismissed else { completion(nil); return }
        let alert = UIAlertController(title: webView.url?.host ?? "Website",
                                      message: String(message.prefix(2_000)), preferredStyle: .alert)
        if kind == .text { alert.addTextField { $0.text = defaultText } }
        let reply = ChatGPTDialogReply { [weak self] value in
            self?.cancelDialog = nil
            self?.activeDialog = nil
            completion(value)
        }
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            reply.resolve(kind == .text ? alert?.textFields?.first?.text ?? "" : "ok")
        })
        if kind != .alert { alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in reply.resolve(nil) }) }
        activeDialog = alert
        cancelDialog = { reply.resolve(nil) }
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        guard !isClearing, owns(webView) else { download.cancel { _ in }; return }
        downloadStarted(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        guard !isClearing, owns(webView) else { download.cancel { _ in }; return }
        downloadStarted(download)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard self.download === download, !isClearing else { completionHandler(nil); return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatGPTDownload-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(ChatGPTWebPolicy.safeFilename(suggestedFilename))
            downloadDirectory = directory
            downloadDestination = destination
            completionHandler(destination)
        } catch {
            completionHandler(nil)
            cancelDownload()
            failure = .init(message: "The downloaded file could not be saved. Check available storage and try again.", code: "download-storage")
        }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping @MainActor @Sendable (WKDownload.RedirectPolicy) -> Void) {
        // Keep WebKit's own authenticated download; never forward cookies to URLSession.
        decisionHandler(self.download === download && !isClearing && ChatGPTWebPolicy.isSecureURL(request.url) ? .allow : .cancel)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard self.download === download else { return }
        downloadFinished()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard self.download === download else { return }
        cancelDownload()
        failure = .init(message: "The download did not finish. Try downloading the file again.", code: "download-failed")
    }
}

/// UIKit dismissal and an already queued button action can race during a data reset.
@MainActor
final class ChatGPTDialogReply {
    private var completion: (@MainActor (String?) -> Void)?

    init(completion: @escaping @MainActor (String?) -> Void) {
        self.completion = completion
    }

    func resolve(_ value: String?) {
        let pending = completion
        completion = nil
        pending?(value)
    }
}
