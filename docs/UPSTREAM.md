# Upstream sources and integration decisions

Inspection date: 2026-11-22. The user-confirmed public remote is `todaysday/codex-app-mobile`. Its main branch was inspected at the base revision below. CI and physical-device acceptance are separate gates. Source revisions below identify the inspected inputs; they are not claims that upstream will remain unchanged.

## Source provenance

| Component | Inspected revision | License and role |
| --- | --- | --- |
| [shuto-S/codex-app-mobile](https://github.com/shuto-S/codex-app-mobile) | [`6ddaa25d6f69288cd8a4e09c1cf8eaec9a89a511`](https://github.com/shuto-S/codex-app-mobile/tree/6ddaa25d6f69288cd8a4e09c1cf8eaec9a89a511) | MIT, Copyright (c) 2026 shuto. Application base, Codex UI, orchestration, terminal, tests, and assets. Full notice remains in [LICENSE](../LICENSE). |
| [Akuma1tko/ChatGPT-WebView](https://github.com/Akuma1tko/ChatGPT-WebView) | [`0d258d90272fcc3a523c8a0b0fef0b0d902f127f`](https://github.com/Akuma1tko/ChatGPT-WebView/tree/0d258d90272fcc3a523c8a0b0fef0b0d902f127f) | MIT, Copyright (c) 2025 Akuma1tko. Minimal WKWebView companion reference. Full notice is in [ChatGPT-WebView-MIT.txt](licenses/ChatGPT-WebView-MIT.txt). |

The original client README is preserved as [UPSTREAM_README.md](UPSTREAM_README.md). It describes the upstream revision, including setup instructions and development defaults that may differ from this fork. The supplied project brief is preserved verbatim as [Codex_ChatGPT_Mobile_Handoff.md](handoff/Codex_ChatGPT_Mobile_Handoff.md).

## Inspected application structure

- The application entrypoint is `CodexAppMobile/App/CodexAppMobileApp.swift`.
- The checked-in shared scheme and application target are named `CodexAppMobile`; the build product is `CodexAppMobile.app`.
- The checked-in project uses Swift 6 and an iOS 18.0 deployment target.
- The existing orchestration module provides hosts, project workspaces, thread operations, model/reasoning/collaboration controls, approvals, and user-input handling.
- The existing terminal module provides SSH fallback and Known Hosts handling.
- Existing host secrets use Keychain; host/project/thread metadata uses UserDefaults.
- The inspected revision already has separate Debug and Release plists: Release disables `NSAllowsArbitraryLoads`, while Debug enables it. The upstream README's broad statement about arbitrary loads is therefore incomplete for this revision.
- Upstream source includes availability-guarded newer SwiftUI APIs; the hosted build selects Xcode 26.2 while retaining iOS 18.0 deployment compatibility.

CI must inspect the actual scheme and build settings with Xcode before packaging; repository inspection is not a substitute for a successful build.

## What is reused from the web donor

The donor demonstrates a native WKWebView opening ChatGPT with persistent web login and microphone-related configuration. The integration carries forward that small browser-companion concept inside the existing SwiftUI app. It does not embed a donor IPA, a second app entrypoint, or an official ChatGPT executable.

The donor's old Safari user-agent override, viewport JavaScript injection, permissive transport exceptions, and unrestricted media behavior are not part of this design. This app uses standard WebKit behavior, explicit browser policy, system permission prompts, and a dedicated persistent website store.

## Decisions and unresolved physical behavior

| Area | Decision | Verification boundary |
| --- | --- | --- |
| Browser profile | Stable named `WKWebsiteDataStore(forIdentifier:)`, supported from iOS 17 | Tests can inspect store identity/persistence; real login persistence needs the iPhone. |
| Data clearing | Confirm and clear only the named store | Verify other website stores and Codex records remain intact; perform physical cross-app checks. |
| OAuth | Ordinary website flow and explicit Safari fallback | The user's actual login method may reject an embedded browser; no automatic cookie bridge is assumed. |
| Existing server | User-entered endpoint and optional proxy authentication | Live connection, TLS, and compatibility depend on the user's existing VPS route. |
| Distribution | Unsigned IPA, later user signing | GitHub CI verifies compilation/packaging; SideStore install and refresh require the device. |
| Later Codex features | Goal Mode, then subagent navigation, then workbench expansion | Proposed separately after MVP acceptance; not claimed implemented by this integration. |

## Primary technical references

- [Codex App Server](https://developers.openai.com/codex/app-server)
- [Apple: named website data store](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/init(foridentifier:))
- [Apple: removing website data](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/removedata(oftypes:modifiedsince:completionhandler:))
- [Apple: SFSafariViewController](https://developer.apple.com/documentation/safariservices/sfsafariviewcontroller)
- [Google: OAuth restrictions for embedded user agents](https://developers.googleblog.com/en/modernizing-oauth-interactions-in-native-apps-for-better-usability-and-security/)
- [GitHub: hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

## Licenses in a distribution

Retain the two full MIT notices and the Swift Package Manager dependency license/NOTICE content required by the versions actually resolved during the build. [THIRD_PARTY_LICENSES.md](../THIRD_PARTY_LICENSES.md) records the upstream inventory. The packaged app must carry these attributions as resources; a source repository link alone is not the final artifact check.
