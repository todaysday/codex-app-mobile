import SwiftUI

enum AppTab: Hashable {
    case codex
    case chatGPT
    case settings
}

@MainActor
final class AppNavigationState: ObservableObject {
    @Published var selectedTab: AppTab = .codex
    var isSceneActive = false

    func shouldNotifyCompletion(isSelectedThread: Bool) -> Bool {
        !(isSceneActive && selectedTab == .codex && isSelectedThread)
    }
}

struct AppShellView: View {
    @EnvironmentObject private var navigation: AppNavigationState
    @ObservedObject var chatGPT: ChatGPTWebProfiles

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            // ContentView already owns the upstream Hosts navigation stack.
            ContentView()
                .tabItem { Label("Codex", systemImage: "terminal") }
                .tag(AppTab.codex)

            NavigationStack {
                ChatGPTWebScreen(model: chatGPT.active, profiles: chatGPT)
                    .id(chatGPT.selectedID)
            }
            .tabItem { Label("ChatGPT", systemImage: "bubble.left.and.bubble.right") }
            .tag(AppTab.chatGPT)

            NavigationStack {
                AppSettingsView(chatGPT: chatGPT) { navigation.selectedTab = .codex }
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
    }
}
