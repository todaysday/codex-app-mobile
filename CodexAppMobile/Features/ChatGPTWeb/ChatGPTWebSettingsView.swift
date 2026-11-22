import SwiftUI

struct ChatGPTWebSettingsView: View {
    @ObservedObject var model: ChatGPTWebViewModel
    @ObservedObject var profiles: ChatGPTWebProfiles
    @State private var confirmsClear = false
    @State private var showsBrowser = false

    static let signInHelp = "Web 1 and Web 2 have independent persistent browser sessions. Neither shares Codex or the official ChatGPT app. Some providers, including Google, may block sign-in inside an embedded browser. Try your usual sign-in method; if it is blocked, use Open in Browser. Signing in there does not sign in this embedded view. Pro features depend on your account and the website."

    var body: some View {
        Form {
            Section("Independent Accounts") {
                Picker("Active web profile", selection: Binding(
                    get: { profiles.selected }, set: { profiles.select($0) }
                )) {
                    ForEach(ChatGPTWebProfiles.Slot.allCases) { slot in Text(slot.title).tag(slot) }
                }
                Text(Self.signInHelp).font(.subheadline)
                Button("Open ChatGPT in Browser", systemImage: "safari") { showsBrowser = true }
                    .disabled(model.isClearing)
            }
            Section("ChatGPT Web Data") {
                Text("Each web profile has its own persistent cookies and website data. Clearing one does not erase the other.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Clear \(profiles.selected.title) Web Data", systemImage: "trash", role: .destructive) { confirmsClear = true }
                    .disabled(model.isClearing)
                if model.isClearing { ProgressView("Clearing web data…") }
            }
            Section("Diagnostics") {
                LabeledContent("Profile", value: profiles.selected.title)
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
        .confirmationDialog("Clear \(profiles.selected.title) web data?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear \(profiles.selected.title) Data", role: .destructive) {
                let selectedModel = model
                Task { await selectedModel.clearWebsiteData() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only \(profiles.selected.title) is cleared. The other web profile, Codex, Safari and the official ChatGPT app retain their local data.")
        }
        .sheet(isPresented: $showsBrowser) { ChatGPTSafariView(url: ChatGPTWebPolicy.homeURL).ignoresSafeArea() }
    }
}
