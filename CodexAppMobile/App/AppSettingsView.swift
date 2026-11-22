import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var chatGPT: ChatGPTWebProfiles
    let openCodex: () -> Void

    var body: some View {
        Form {
            Section("Codex") {
                Button(action: openCodex) {
                    Label("Open Codex", systemImage: "terminal")
                }
                Text("Manage hosts and server connections in Codex. Your current session stays open when switching tabs.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("ChatGPT") {
                NavigationLink {
                    ChatGPTWebSettingsView(model: chatGPT.active, profiles: chatGPT)
                        .id(chatGPT.selectedID)
                } label: {
                    Label("Web Account and Browser Data", systemImage: "globe")
                }
                Text("Manage multiple independently signed-in web profiles under this menu. Codex and the official ChatGPT app retain their own sessions.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("App", value: "Codex Mobile")
                LabeledContent("Version", value: version)
                LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "Unavailable")
                    .font(.footnote)
                NavigationLink {
                    AppAttributionView()
                } label: {
                    Label("Open Source Licenses", systemImage: "doc.text")
                }
                Link(destination: URL(string: "https://github.com/todaysday/codex-app-mobile")!) {
                    Label("Project Repository", systemImage: "arrow.up.right.square")
                }
            }
        }
        .navigationTitle("Settings")
    }

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}

struct AppAttributionView: View {
    private let documents = AppLicenseDocument.bundled()

    var body: some View {
        List {
            Section {
                Text("Codex Mobile builds on CodexAppMobile and uses ChatGPT-WebView as a companion reference. Their licenses and the notices of bundled dependencies are included below.")
                    .font(.subheadline)
            }
            if documents.isEmpty {
                Text("License resources are missing from this build. The project repository includes the complete notices.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(documents) { document in
                    NavigationLink(document.title) {
                        ScrollView {
                            Text(document.content)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .navigationTitle(document.title)
                        .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
        }
        .navigationTitle("Open Source Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AppLicenseDocument: Identifiable {
    let id: String
    let title: String
    let content: String

    static func bundled(in bundle: Bundle = .main) -> [AppLicenseDocument] {
        guard let directory = bundle.url(forResource: "Attribution", withExtension: nil),
              let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var documents: [AppLicenseDocument] = []
        for case let url as URL in files {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty else { continue }
            let relativePath = String(url.path.dropFirst(directory.path.count + 1))
            documents.append(.init(id: relativePath, title: relativePath, content: content))
        }
        return documents.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
