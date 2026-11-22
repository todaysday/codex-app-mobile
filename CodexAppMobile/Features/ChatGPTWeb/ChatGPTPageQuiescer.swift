import Foundation
@preconcurrency import WebKit

/// Explicit reset is the only time a live ChatGPT document is deliberately discarded.
@MainActor
final class ChatGPTPageQuiescer: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?
    private var blankNavigation: WKNavigation?

    func blank(_ webView: WKWebView) async -> Bool {
        webView.stopLoading()
        webView.isUserInteractionEnabled = false
        webView.uiDelegate = nil
        webView.navigationDelegate = self
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.finish(false)
            }
            blankNavigation = webView.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
            if blankNavigation == nil { finish(false) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, navigation === blankNavigation else { return }
        finish(true)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Queued callbacks from the previous page cannot complete this reset.
        guard let navigation, navigation === blankNavigation else { return }
        finish(false)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === blankNavigation else { return }
        finish(false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(true)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    private func finish(_ result: Bool) {
        timeout?.cancel()
        timeout = nil
        blankNavigation = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
}
