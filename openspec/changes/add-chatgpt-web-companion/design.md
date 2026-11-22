# Design

## Application composition

The existing `CodexAppMobileApp` remains the single entrypoint and keeps its existing `@StateObject` ownership of `AppState`. A tab shell receives that same state through the environment and owns three stable destinations: Codex, ChatGPT, and Settings. Ordinary launch selects Codex. The application or its stable shell owns one ChatGPT browser model for its lifetime. SwiftUI updates and tab selection do not recreate either connection state or the browser.

The Codex destination embeds the existing root interface. Settings routes to host management without constructing a second AppState or App Server client. Browser data controls are shared with the same ChatGPT model, so clearing data cannot target an unrelated store.

The inspected upstream integrates its splash in a private `AppRootView` in `CodexAppMobileApp.swift`; add the tab shell at that existing composition boundary rather than introducing a second app entrypoint or a conflicting root type. `ContentView` in `CodexOrchestrationViews.swift` retains Hosts and the Terminal sheet, while `SessionWorkbenchView` owns the existing conversation UI. The checked-in project uses explicit file membership, so new sources and resources must be added to the actual Xcode targets. Existing workbench Git/diff features remain available even though expanded Git/worktree capabilities are future work.

## Website storage and clearing

Use `WKWebsiteDataStore(forIdentifier:)` with a constant application-owned UUID. The deployment target supports this API. A named persistent store gives ChatGPT and its identity-provider redirects one isolated browser profile; clearing it includes the associated login data without touching any other WebKit store, Safari, Codex Keychain records, or the App Store ChatGPT app.

The handoff initially names `.default()` but explicitly permits a dedicated persistent store where supported. The named store is the chosen implementation of that isolation requirement. It must never be replaced by `.nonPersistent()` for ordinary use, and its identifier must remain stable through application updates.

Clearing requires an explicit destructive confirmation. The implementation blocks overlapping clears and navigation while it stops existing page activity, removes the dedicated store's website data, and prepares a clean browser state. It must not leave an old authenticated document visible as if it represented a fresh session. Tests must distinguish this store from the default store and verify that Codex records are untouched.

## Navigation and login

The initial page is `https://chatgpt.com`. Use WebKit's normal user agent and platform handling. Do not copy the donor's old Safari user-agent override, viewport JavaScript, arbitrary network-load exceptions, or unrestricted media policy.

Support the required official login redirects without inventing an OAuth client. Treat untrusted external destinations, non-HTTPS schemes, unsolicited popup requests, and unsupported downloads explicitly. Only an intentional user action should open an external browser. Never copy website cookies, credentials, or authorization callback values into Codex, UserDefaults, logs, or an external URL.

Do not add third-party analytics or tracking SDKs. Website sign-out remains the website's own account action; the application's separate clear-data action affects only its dedicated browser profile.

The UI shows progress and recoverable navigation failures. Login help states that an identity provider may reject an embedded browser. The SafariServices browser fallback opens the official site's public HTTPS entrypoint; it does not forward a current OAuth URL or promise that Safari authentication will transfer into WebKit. A real login check remains a physical-device gate.

## Camera, microphone, and file interactions

Declare only the platform privacy usage strings required by supported website interactions. Media access remains an explicit WebKit/iOS permission request for a trusted origin, not a blanket grant. Ordinary HTML file selection may use WebKit's system picker. Any unimplemented download or unsupported content flow must present a fallback instead of reporting a completed operation. Actual ChatGPT upload, microphone, and permission-denial behavior is recorded during device acceptance.

## Existing-server transport

The endpoint is user configuration, never a baked-in VPS address. Preserve scheme, host, path, and explicit port when storing and editing a valid endpoint. Release builds retain TLS validation; no unprotected public WebSocket or certificate bypass is introduced. Legacy host configuration must remain readable, and invalid endpoints must fail before a network connection or credential transmission.

Optional proxy authentication belongs in Keychain and is added only to the intended App Server WebSocket handshake. A Cloudflare Access deployment requires the corresponding service-token headers; it is not declared working just because a host URL is reachable. Authentication values must not be copied to ChatGPT navigation or included in diagnostic output. The existing process keeps its VPS-side `CODEX_HOME` and OpenAI account.

## Build and installation

The repository preserves the checked-in shared `CodexAppMobile` scheme and target. CI runs `xcodebuild -list` and inspects build settings, then executes available simulator tests and performs an iPhoneOS Release build with signing disabled. Packaging discovers the actual built application, checks its identity and executable, preserves required bundle resources and dependency notices, and archives it under `Payload/`.

The output is an unsigned IPA for user signing. CI never requests an Apple ID, provisioning profile, certificate, or production account cookie. The app has its own bundle identity and uses the upstream icon assets; an official ChatGPT bundle or executable is not embedded.

## Verification boundaries

Source inspection verifies the isolation boundaries and that the existing Codex stack is retained. Unit/integration checks cover browser policy and lifecycle where simulator APIs permit, endpoint preservation, secret storage, and build packaging. CI is the authoritative compiler/test execution environment when local Xcode is absent.

The user must perform the final real-account login and installation gates on the requested iPhone. Until then, documentation must distinguish implemented source, tests that ran, an actually downloaded CI artifact, and unresolved device behavior. Later Goal Mode/subagent work must not obscure an unresolved MVP login failure.
