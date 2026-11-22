import SwiftUI

struct ChatGPTWebSettingsView: View {
    @ObservedObject var model: ChatGPTWebViewModel
    @ObservedObject var profiles: ChatGPTWebProfiles
    @State private var showsBrowser = false
    @State private var showsProfileNameDialog = false
    @State private var editingProfileID: UUID?
    @State private var profileNameDraft = ""
    @State private var clearTargetID: UUID?
    @State private var deleteTargetID: UUID?

    static let signInHelp = "Each web profile has its own persistent ChatGPT session, independent of other profiles, Codex, and the official ChatGPT app. Create new profiles explicitly below. Some providers, including Google, may block sign-in inside an embedded browser. If blocked, use Open in Browser; that sign-in does not automatically transfer. Web features depend on each account."

    private var pendingConfirmationID: UUID? { deleteTargetID ?? clearTargetID }
    private var pendingConfirmationName: String {
        pendingConfirmationID.flatMap { profiles.profile(id: $0)?.name } ?? "web profile"
    }

    var body: some View {
        Form {
            Section("Web Profiles") {
                ForEach(profiles.profiles) { profile in
                    HStack {
                        Button {
                            profiles.select(profile.id)
                        } label: {
                            HStack {
                                Text(profile.name).foregroundStyle(.primary)
                                if profiles.selectedID == profile.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 8)
                        Menu {
                            Button("Rename", systemImage: "pencil") {
                                editingProfileID = profile.id
                                profileNameDraft = profile.name
                                showsProfileNameDialog = true
                            }
                            if profiles.profiles.count > 1 {
                                Button("Delete Profile", systemImage: "trash", role: .destructive) {
                                    deleteTargetID = profile.id
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").imageScale(.large)
                        }
                        .accessibilityLabel("Manage \(profile.name)")
                    }
                    .disabled(profiles.isRemovingProfile)
                }
                Button("Add Web Profile", systemImage: "plus") {
                    editingProfileID = nil
                    profileNameDraft = ""
                    showsProfileNameDialog = true
                }
                .disabled(profiles.isRemovingProfile)
                Text("Add as many independent accounts as needed. Existing profiles keep their own website data and open pages.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(Self.signInHelp).font(.footnote).foregroundStyle(.secondary)
                Button("Open ChatGPT in Browser", systemImage: "safari") { showsBrowser = true }
                    .disabled(model.isClearing || profiles.isRemovingProfile)
            }
            Section("Selected Profile Data") {
                LabeledContent("Selected", value: profiles.selectedName)
                Button("Clear \(profiles.selectedName) Web Data", systemImage: "trash", role: .destructive) {
                    clearTargetID = profiles.selectedID
                }
                .disabled(model.isClearing || profiles.isRemovingProfile)
                if model.isClearing || profiles.isRemovingProfile { ProgressView("Updating web profile…") }
                if let error = profiles.managementError {
                    Text(error).font(.subheadline).foregroundStyle(.red)
                }
            }
            Section("Diagnostics") {
                LabeledContent("Website", value: model.currentHost)
                LabeledContent("Storage", value: "Persistent, independently named WebKit store")
                LabeledContent("Page", value: model.isLoading ? "Loading" : "Idle")
                if let failure = model.failure {
                    LabeledContent("Error code", value: failure.code)
                    Text(failure.message).font(.subheadline)
                }
                Text("Diagnostics never include cookies, tokens, OAuth addresses or usernames.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("ChatGPT Web Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .alert(editingProfileID == nil ? "Add Web Profile" : "Rename Web Profile",
               isPresented: $showsProfileNameDialog) {
            TextField("Profile name (optional for new profiles)", text: $profileNameDraft)
            Button(editingProfileID == nil ? "Add" : "Save") {
                if let id = editingProfileID {
                    _ = profiles.renameProfile(id: id, to: profileNameDraft)
                } else {
                    _ = profiles.addProfile(name: profileNameDraft)
                }
                editingProfileID = nil
            }
            Button("Cancel", role: .cancel) { editingProfileID = nil }
        } message: {
            Text("Names are stored only on this device. Your ChatGPT sign-in stays inside that profile's WebKit storage.")
        }
        .confirmationDialog(deleteTargetID == nil ? "Clear \(pendingConfirmationName) data?"
                            : "Delete \(pendingConfirmationName)?",
                            isPresented: Binding(
                                get: { pendingConfirmationID != nil },
                                set: { if !$0 { clearTargetID = nil; deleteTargetID = nil } }
                            ), titleVisibility: .visible) {
            if let id = deleteTargetID {
                Button("Delete Profile and Website Data", role: .destructive) {
                    deleteTargetID = nil
                    Task { _ = await profiles.removeProfile(id: id) }
                }
            } else if let id = clearTargetID {
                Button("Clear Profile Website Data", role: .destructive) {
                    clearTargetID = nil
                    if profiles.profile(id: id) != nil {
                        let target = profiles.model(for: id)
                        Task { await target.clearWebsiteData() }
                    }
                }
            }
            Button("Cancel", role: .cancel) { clearTargetID = nil; deleteTargetID = nil }
        } message: {
            Text("Only this named profile will be affected; other web profiles and Codex remain unchanged.")
        }
        .sheet(isPresented: $showsBrowser) {
            ChatGPTSafariView(url: ChatGPTWebPolicy.homeURL).ignoresSafeArea()
        }
    }
}
