# Codex Mobile

## Purpose

Codex Mobile is a standalone SwiftUI iPhone client for an existing remote Codex App Server, with a secondary ChatGPT Web tab. The two services may use different OpenAI accounts. The app preserves the upstream Codex client instead of replacing it.

The user authorized both specifications and implementation on 2026-11-22. The initial requirements are preserved in [the supplied handoff](../docs/handoff/Codex_ChatGPT_Mobile_Handoff.md).

## Scope and platform

- Base: `shuto-S/codex-app-mobile`, revision recorded in [UPSTREAM.md](../docs/UPSTREAM.md).
- Delivery repository: `todaysday/codex-app-mobile`, as clarified by the user; the local checkout directory name does not change the GitHub destination.
- Swift 6, SwiftUI, UIKit/WebKit, URLSession WebSocket, existing Swift Package Manager dependencies.
- Deployment target: iOS 18.0; first requested physical test device: iPhone running iOS 18.7.8.
- Distribution: unsigned IPA from GitHub-hosted macOS, then user signing with SideStore or Impactor.
- Separate bundle identity; the app runs directly on iOS, outside LiveContainer.
- No new server process, ChatGPT backend, analytics SDK, subscription, or OpenAI API credential is required by this change.

## Architecture and invariants

1. Codex retains its upstream host, project, thread, model, approval, terminal, and notification behavior.
2. App-level ownership keeps the Codex state and ChatGPT browser alive across tab changes.
3. ChatGPT uses a dedicated persistent `WKWebsiteDataStore(forIdentifier:)` with a stable identifier. This is the iOS 17+ isolation refinement explicitly allowed by the handoff; it replaces the shared default store recommendation.
4. Codex connection secrets belong in Keychain. Website data belongs in the dedicated WebKit store. Neither module reads or copies the other's credentials.
5. Release connections use a protected transport to the existing App Server. ChatGPT navigates to the official HTTPS site without injected authentication code or a spoofed user agent.
6. A successful build does not establish real-device OAuth, account isolation, SideStore installation, or signature refresh success.

## Specifications and status

The active change is [add-chatgpt-web-companion](changes/add-chatgpt-web-companion/proposal.md). Its capability deltas describe the behavior being added. Tasks distinguish source implementation, automated checks, CI evidence, and physical acceptance.

The preserved upstream behavior is the starting baseline. No active change is marked fully accepted until its outstanding live gates pass. Goal Mode, subagent navigation, and later workbench enhancements remain [proposed follow-up work](../docs/ROADMAP.md).

## Development conventions

Follow [AGENTS.md](../AGENTS.md). Keep changes isolated and dependency-free where first-party frameworks suffice. Use `make` as the command entrypoint and retain the existing local simulator commands. Add tests for isolation, navigation policy, endpoint/credential handling, and artifact construction rather than tests that merely reproduce implementation text.

## Verification evidence

- Automated tests check locally controllable policy and state behavior.
- macOS CI must inspect the actual shared scheme and build settings before compiling and packaging the application.
- [DEVICE_ACCEPTANCE.md](../docs/DEVICE_ACCEPTANCE.md) is the release gate for the user's device, real account, and existing VPS.
- Credentials, cookies, authorization codes, and private conversation content must not be included in public evidence.
