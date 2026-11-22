import SwiftUI

struct ChatGPTWebSettingsView: View {
    @ObservedObject var model: ChatGPTWebViewModel
    @State private var confirmsClear = false
    @State private var showsBrowser = false

    static let signInHelp = "This browser has its own ChatGPT account, independent of Codex and the official ChatGPT app. Some providers, including Google, may block sign-in inside an embedded browser. Try your usual sign-in method; if it is blocked, use Open in Browser. Signing in there does not sign in this embedded view. Pro features depend on your account and the website."

    var body: some View {
        Form {
            Section("Independent Accounts") {
                Text(Self.signInHelp).font(.subheadline)
                Button("Open ChatGPT in Browser", systemImage: "safari") { showsBrowser = true }
                    .disabled(model.isClearing)
            }
            Section("ChatGPT Web Data") {
                Text("Sign-in data is stored on this device in a dedicated persistent browser profile.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Clear ChatGPT Web Data", systemImage: "trash", role: .destructive) { confirmsClear = true }
                    .disabled(model.isClearing)
                if model.isClearing { ProgressView("Clearing web data…") }
            }
            Section("Diagnostics") {
                LabeledContent("Website", value: model.currentHost)
                LabeledContent("Storage", value: "Persistent, isolated profile")
                LabeledContent("Page", value: model.isLoading ? "Loading" : "Idle")
                if let failure = model.failure {
                    LabeledContent("Error code", value: failure.code)
                    Text(failure.message).font(.subheadline)
                }
                Text("Diagnostics omit full addresses, cookies and account tokens.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("ChatGPT Web")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear ChatGPT web data?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear Web Data", role: .destructive) { Task { await model.clearWebsiteData() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This signs out only the embedded ChatGPT browser and removes its website data and temporary downloads. Codex, Safari and the official ChatGPT app are unaffected.")
        }
        .sheet(isPresented: $showsBrowser) { ChatGPTSafariView(url: ChatGPTWebPolicy.homeURL).ignoresSafeArea() }
    }
}
