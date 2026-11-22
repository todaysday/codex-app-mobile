import SafariServices
import SwiftUI
import WebKit

struct ChatGPTWebScreen: View {
    @ObservedObject var model: ChatGPTWebViewModel
    @State private var confirmsClear = false
    @State private var showsSignInHelp = false

    var body: some View {
        VStack(spacing: 0) {
            if model.isLoading {
                ProgressView(value: model.progress).accessibilityLabel("Page loading")
            }
            if let failure = model.failure {
                ChatGPTWebErrorBanner(failure: failure, reload: model.reload, browser: model.openBrowser)
            }
            if let webView = model.webView, !model.isClearing {
                ChatGPTWebView(webView: webView)
                    .id(ObjectIdentifier(webView))
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(model.isClearing ? "Clearing ChatGPT web data…" : "Opening ChatGPT…")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.isDownloading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Downloading file…").font(.caption)
                    Spacer()
                    Button("Cancel", action: model.cancelDownload).font(.caption)
                }
                .padding(.horizontal).padding(.vertical, 8)
            }
        }
        .navigationTitle("ChatGPT")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button(action: model.goBack) { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Back").disabled(!model.canGoBack || model.isClearing)
                Button(action: model.goForward) { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Forward").disabled(!model.canGoForward || model.isClearing)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: model.reload) { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Reload ChatGPT").disabled(model.isClearing)
                Menu {
                    Button("ChatGPT Home", systemImage: "house", action: model.goHome)
                    Button("Open in Browser", systemImage: "safari", action: model.openBrowser)
                    Button("Sign-in Help", systemImage: "questionmark.circle") { showsSignInHelp = true }
                    if model.readyDownload != nil {
                        Button("Share Download", systemImage: "square.and.arrow.up", action: model.presentReadyDownload)
                    }
                    Divider()
                    Button("Clear ChatGPT Web Data", systemImage: "trash", role: .destructive) { confirmsClear = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("ChatGPT options").disabled(model.isClearing)
            }
        }
        .task(id: model.isClearing) { model.loadIfNeeded() }
        .confirmationDialog("Clear ChatGPT web data?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear Web Data", role: .destructive) { Task { await model.clearWebsiteData() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This signs out the embedded ChatGPT browser and removes its cookies, website data and temporary downloads. Codex, Safari and the official ChatGPT app keep their own accounts.")
        }
        .alert("Signing in to ChatGPT", isPresented: $showsSignInHelp) {
            Button("Open in Browser", action: model.openBrowser)
            Button("OK", role: .cancel) { }
        } message: {
            Text(ChatGPTWebSettingsView.signInHelp)
        }
        .sheet(item: Binding(get: { model.sheet }, set: { if $0 == nil { model.dismissSheet() } }),
               onDismiss: model.sheetDidDismiss) { sheet in
            switch sheet {
            case .popup(let popup):
                ChatGPTWebPopupScreen(popup: popup, model: model)
            case .browser(let url):
                ChatGPTSafariView(url: url)
                    .ignoresSafeArea()
            case .download(let file):
                ChatGPTShareSheet(url: file.url)
            }
        }
    }
}

struct ChatGPTWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
    // SwiftUI may dismantle the bridge on a tab switch. The root model retains the view.
}

private struct ChatGPTWebErrorBanner: View {
    let failure: ChatGPTWebFailure
    let reload: () -> Void
    let browser: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(failure.message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
            HStack {
                Button("Reload", action: reload)
                Spacer()
                Button("Open in Browser", action: browser)
            }
            .font(.subheadline)
        }
        .padding()
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }
}

private struct ChatGPTWebPopupScreen: View {
    let popup: ChatGPTWebPopup
    @ObservedObject var model: ChatGPTWebViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let failure = model.failure {
                    Text(failure.message).font(.subheadline).padding().frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                }
                ChatGPTWebView(webView: popup.webView)
            }
            .navigationTitle("ChatGPT Web Window")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: model.dismissSheet) }
            }
        }
    }
}

struct ChatGPTSafariView: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) { }

    @MainActor
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { dismiss() }
    }
}

private struct ChatGPTShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
