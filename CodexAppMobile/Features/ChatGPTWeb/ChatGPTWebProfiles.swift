import Combine
import Foundation

/// A local browser profile, not an identity inferred from website credentials.
struct ChatGPTWebProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String

    static let initial = ChatGPTWebProfile(id: ChatGPTWebPolicy.storeIdentifier, name: "Account 1")
}

enum ChatGPTWebProfileError: LocalizedError, Equatable {
    case invalidName, duplicateName, busy, missingProfile, lastProfile, clearFailed

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Use a name from 1 to 60 characters without line breaks or control characters."
        case .duplicateName: return "Another profile already has this name. Choose a different name."
        case .busy: return "Finish or dismiss the current browser interaction before changing profiles."
        case .missingProfile: return "This profile is no longer available."
        case .lastProfile: return "Keep at least one profile. You can clear its website data or add another profile."
        case .clearFailed: return "The profile could not be cleared safely. Open it, reload the page, and try again. The profile has been kept."
        }
    }
}

@MainActor
final class ChatGPTWebProfiles: ObservableObject {
    static let registryDefaultsKey = "chatgpt.web.profiles.v1"

    @Published private(set) var profiles: [ChatGPTWebProfile]
    @Published private(set) var selectedProfileID: UUID
    @Published private(set) var deletingProfileID: UUID?
    private let defaults: UserDefaults
    private let initialURL: URL
    private var models: [UUID: ChatGPTWebViewModel] = [:]

    private struct Registry: Codable {
        let version: Int
        let profiles: [ChatGPTWebProfile]
        let selectedProfileID: UUID
    }

    init(defaults: UserDefaults = .standard, initialProfile: ChatGPTWebProfile = .initial,
         initialURL: URL = ChatGPTWebPolicy.homeURL) {
        self.defaults = defaults
        self.initialURL = initialURL
        let saved = defaults.data(forKey: Self.registryDefaultsKey)
            .flatMap { try? JSONDecoder().decode(Registry.self, from: $0) }
        if let saved, saved.version == 1, !saved.profiles.isEmpty,
           Set(saved.profiles.map(\.id)).count == saved.profiles.count {
            profiles = saved.profiles
            selectedProfileID = saved.profiles.contains(where: { $0.id == saved.selectedProfileID })
                ? saved.selectedProfileID : saved.profiles[0].id
        } else {
            profiles = [initialProfile]
            selectedProfileID = initialProfile.id
        }
        persist()
    }

    var selectedProfile: ChatGPTWebProfile { profiles.first(where: { $0.id == selectedProfileID }) ?? profiles[0] }
    var selectedModel: ChatGPTWebViewModel { model(for: selectedProfileID)! }
    var isDeleting: Bool { deletingProfileID != nil }
    var canChangeSelection: Bool { !isDeleting && (models[selectedProfileID]?.canSwitchProfile ?? true) }

    var suggestedName: String {
        var number = profiles.count + 1
        while profiles.contains(where: { $0.name.caseInsensitiveCompare("Account \(number)") == .orderedSame }) {
            number += 1
        }
        return "Account \(number)"
    }

    func model(for id: UUID) -> ChatGPTWebViewModel? {
        guard profiles.contains(where: { $0.id == id }) else { return nil }
        if let model = models[id] { return model }
        let model = ChatGPTWebViewModel(storeIdentifier: id, initialURL: initialURL)
        models[id] = model
        return model
    }

    @discardableResult
    func select(_ id: UUID) -> Bool {
        guard profiles.contains(where: { $0.id == id }), !isDeleting else { return false }
        guard id != selectedProfileID else { return true }
        guard canChangeSelection else { return false }
        selectedProfileID = id
        persist()
        return true
    }

    @discardableResult
    func addProfile(named name: String) throws -> ChatGPTWebProfile {
        guard canChangeSelection else { throw ChatGPTWebProfileError.busy }
        let profile = ChatGPTWebProfile(id: UUID(), name: try validatedName(name))
        profiles.append(profile)
        selectedProfileID = profile.id
        persist()
        return profile
    }

    func renameProfile(id: UUID, to name: String) throws {
        guard !isDeleting else { throw ChatGPTWebProfileError.busy }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ChatGPTWebProfileError.missingProfile }
        profiles[index].name = try validatedName(name, excluding: id)
        persist()
    }

    func canDeleteProfile(id: UUID) -> Bool {
        profiles.count > 1 && canChangeSelection && profiles.contains(where: { $0.id == id })
            && (models[id]?.canSwitchProfile ?? true)
    }

    func deleteProfile(id: UUID) async throws {
        guard canChangeSelection else { throw ChatGPTWebProfileError.busy }
        guard profiles.count > 1 else { throw ChatGPTWebProfileError.lastProfile }
        guard let model = model(for: id) else { throw ChatGPTWebProfileError.missingProfile }
        guard model.canSwitchProfile else { throw ChatGPTWebProfileError.busy }
        deletingProfileID = id
        defer { deletingProfileID = nil }
        // Keep the registry entry until every owned document has stopped and its store is empty.
        guard await model.clearWebsiteData(retiringProfile: true) else { throw ChatGPTWebProfileError.clearFailed }
        let remaining = profiles.filter { $0.id != id }
        if selectedProfileID == id { selectedProfileID = remaining[0].id }
        profiles = remaining
        models.removeValue(forKey: id)
        persist()
    }

    private func validatedName(_ value: String, excluding id: UUID? = nil) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else {
            throw ChatGPTWebProfileError.invalidName
        }
        guard !profiles.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ChatGPTWebProfileError.duplicateName
        }
        return name
    }

    private func persist() {
        let registry = Registry(version: 1, profiles: profiles, selectedProfileID: selectedProfileID)
        if let data = try? JSONEncoder().encode(registry) {
            defaults.set(data, forKey: Self.registryDefaultsKey)
        }
    }
}
