import SwiftUI

struct ChatGPTWebProfilesSettingsView: View {
    @ObservedObject var profiles: ChatGPTWebProfiles

    var body: some View {
        ChatGPTWebProfileList(profiles: profiles, model: profiles.selectedModel)
    }
}

private struct ChatGPTWebProfileList: View {
    @ObservedObject var profiles: ChatGPTWebProfiles
    @ObservedObject var model: ChatGPTWebViewModel
    @State private var editor: ChatGPTWebProfileEdit?
    @State private var profileToDelete: ChatGPTWebProfile?
    @State private var deletionError: String?

    var body: some View {
        Form {
            Section {
                ForEach(profiles.profiles) { profile in
                    HStack {
                        Button {
                            _ = profiles.select(profile.id)
                        } label: {
                            HStack {
                                Image(systemName: profile.id == profiles.selectedProfileID ? "checkmark.circle.fill" : "circle")
                                Text(profile.name).foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.canSwitchProfile || profiles.isDeleting)
                        .accessibilityLabel("Select \(profile.name)")
                        if profiles.deletingProfileID == profile.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Menu {
                                Button("Rename", systemImage: "pencil") {
                                    editor = .init(profile: profile, initialName: profile.name)
                                }
                                Button("Delete Profile", systemImage: "trash", role: .destructive) {
                                    profileToDelete = profile
                                }
                                .disabled(!profiles.canDeleteProfile(id: profile.id))
                            } label: { Image(systemName: "ellipsis.circle") }
                            .disabled(profiles.isDeleting)
                            .accessibilityLabel("Manage \(profile.name)")
                        }
                    }
                }
                Button("Add Web Account", systemImage: "plus") {
                    editor = .init(profile: nil, initialName: profiles.suggestedName)
                }
                .disabled(!model.canSwitchProfile || profiles.isDeleting)
                .accessibilityIdentifier("chatgpt-add-profile")
            } header: {
                Text("Web Accounts")
            } footer: {
                Text("Each profile keeps its own website login and browser history. Add a profile for each account you want to use. At least one profile stays available; you can clear its website data.")
            }
            Section("Selected Profile") {
                NavigationLink {
                    ChatGPTWebSettingsView(model: model, profile: profiles.selectedProfile)
                } label: {
                    Label("\(profiles.selectedProfile.name): Website Data and Diagnostics", systemImage: "globe")
                }
                if !model.canSwitchProfile {
                    Text("Finish or dismiss this account’s browser interaction in ChatGPT before switching or adding accounts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Signing In") {
                Text(ChatGPTWebSettingsView.signInHelp).font(.subheadline)
            }
        }
        .navigationTitle("Web Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editor) { request in
            ChatGPTWebProfileEditor(profiles: profiles, request: request)
        }
        .confirmationDialog("Delete \(profileToDelete?.name ?? "profile")?", isPresented: Binding(
            get: { profileToDelete != nil }, set: { if !$0 { profileToDelete = nil } }
        ), titleVisibility: .visible) {
            if let target = profileToDelete {
                Button("Delete Profile", role: .destructive) {
                    Task {
                        do { try await profiles.deleteProfile(id: target.id) }
                        catch { deletionError = error.localizedDescription }
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This signs out only this profile, removes its website data and temporary downloads, and deletes it from the account list. Other web profiles, Codex, Safari and the official ChatGPT app keep their own data.")
        }
        .alert("Could Not Delete Profile", isPresented: Binding(
            get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(deletionError ?? "Try again.")
        }
    }
}

private struct ChatGPTWebProfileEdit: Identifiable {
    let id = UUID()
    let profile: ChatGPTWebProfile?
    let initialName: String
}

private struct ChatGPTWebProfileEditor: View {
    @ObservedObject var profiles: ChatGPTWebProfiles
    let request: ChatGPTWebProfileEdit
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var errorMessage: String?

    init(profiles: ChatGPTWebProfiles, request: ChatGPTWebProfileEdit) {
        self.profiles = profiles
        self.request = request
        _name = State(initialValue: request.initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile Name") {
                    TextField("For example, Personal or Work", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit(save)
                    Text("Choose a local label. Sign in to the account through the ChatGPT website after selecting this profile.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let errorMessage { Text(errorMessage).font(.subheadline).foregroundStyle(.red) }
                }
            }
            .navigationTitle(request.profile == nil ? "Add Web Account" : "Rename Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.profile == nil ? "Add" : "Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profiles.isDeleting)
                }
            }
        }
    }

    private func save() {
        do {
            if let profile = request.profile { try profiles.renameProfile(id: profile.id, to: name) }
            else { try profiles.addProfile(named: name) }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct ChatGPTWebSettingsView: View {
    @ObservedObject var model: ChatGPTWebViewModel
    let profile: ChatGPTWebProfile
    @State private var confirmsClear = false
    @State private var showsBrowser = false

    static let signInHelp = "Add a separate browser profile in Web Accounts for each ChatGPT account. Each profile is independent of the others, Codex and the official ChatGPT app. Some providers, including Google, may block sign-in inside an embedded browser. Try your usual sign-in method; if it is blocked, use Open in Browser. Signing in there does not sign in this embedded view. Pro features depend on your account and the website."

    var body: some View {
        Form {
            Section("Independent Accounts") {
                Text(Self.signInHelp).font(.subheadline)
                Button("Open ChatGPT in Browser", systemImage: "safari") { showsBrowser = true }
                    .disabled(model.isClearing)
            }
            Section("\(profile.name) Web Data") {
                Text("Sign-in data for \(profile.name) stays in its own persistent browser profile on this device. Clearing it leaves other profiles’ local sign-in data intact.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Clear \(profile.name) Web Data", systemImage: "trash", role: .destructive) { confirmsClear = true }
                    .disabled(model.isClearing)
                if model.isClearing { ProgressView("Clearing web data…") }
            }
            Section("Diagnostics") {
                LabeledContent("Profile", value: profile.name)
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
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear \(profile.name) web data?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear Web Data", role: .destructive) {
                let confirmedModel = model
                Task { await confirmedModel.clearWebsiteData() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This signs out only \(profile.name) and removes its website data and temporary downloads. Other web profiles, Codex, Safari and the official ChatGPT app are unaffected.")
        }
        .sheet(isPresented: $showsBrowser) { ChatGPTSafariView(url: ChatGPTWebPolicy.homeURL).ignoresSafeArea() }
    }
}
