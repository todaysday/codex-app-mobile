# Add an isolated ChatGPT Web companion to Codex Mobile

## Why

The user needs one independently installed iPhone app that operates the Codex App Server already running on a VPS and also opens the user's separate ChatGPT web account. Replacing the upstream Codex UI would discard working host, thread, and approval features. Sharing authorization between the two products would violate the required account separation.

## What Changes

- Preserve CodexAppMobile as the application base and expose it as the default Codex tab.
- Add a long-lived ChatGPT Web view, browser controls, bounded navigation/error handling, an explicit Safari fallback, and confirmed clearing of only its persistent website store.
- Add Settings for the existing host configuration entrypoint, ChatGPT data/diagnostics, attribution, and build identity.
- Preserve full secure App Server endpoints and keep connection authentication in Keychain.
- Add hosted macOS checks and unsigned IPA packaging, preserving upstream and dependency notices.
- Document source provenance, physical acceptance, installation, and the next proposed Codex capabilities.

## Impact

Affected capabilities: `app-shell`, `isolated-chatgpt-web`, `secure-existing-codex`, and `unsigned-ios-distribution`.

Affected implementation areas: app root wiring, a new ChatGPTWeb feature directory, host endpoint/credential handling, plist and Xcode target membership, tests, build scripts, GitHub Actions, and documentation. Existing orchestration and SSH terminal functionality stays the baseline.

No migration of ChatGPT credentials is performed. Existing Codex host metadata must remain readable, and legacy endpoint data must not silently downgrade a secure address when edited. There is no change to the VPS process or to either account's server-side authentication.

## Authorization and delivery status

Specification creation and implementation are authorized by the user's request. A second approval step is unnecessary for this change. Implementation status is recorded in [tasks.md](tasks.md); physical acceptance remains separate from code completion.

The initial release is an MVP candidate until the exact IPA has passed the real iPhone sign-in, account isolation, existing-server, installation, and signature-refresh scenarios. In particular, opening Safari does not prove that login works inside WKWebView.

## Out of scope

- A custom ChatGPT backend, account merger, API-key replacement for ChatGPT Web, token bridging, automatic cross-tab content exchange, or CAPTCHA/attestation workarounds.
- Starting or replacing the already running Codex App Server.
- Guaranteed background WebSocket connectivity or remote push infrastructure.
- Goal Mode, subagent tree UI, and new Git/worktree/diff functionality before successful MVP device acceptance; these are specified as follow-up proposals in [ROADMAP.md](../../../docs/ROADMAP.md).

## Acceptance

All automated build and policy checks must pass, and the physical checklist in [DEVICE_ACCEPTANCE.md](../../../docs/DEVICE_ACCEPTANCE.md) must record evidence for the tested commit and IPA. A failed or untested authentication method must remain visibly unresolved.
