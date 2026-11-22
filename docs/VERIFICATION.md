# Build and verification record

This record separates source validation, hosted iOS verification, and physical-device acceptance.

## Current review fixes

The current source adds an extensible named web-profile registry with Settings Add/Rename/Delete, structured subagent cards, WSS-only hosts, workspace file previews and worktree tools. Portable validation passes with 60 registered Swift files, seven OpenSpec changes, 64 requirements and 160 scenarios, plus eight Python tooling tests. The full macOS XCTest/Release run for these changes is pending; the baseline evidence below does not certify the new source. Real ChatGPT authentication, the existing VPS and physical-device gates remain pending.

## Previous verified baseline

- Repository: `todaysday/codex-app-mobile`
- Code commit: `0a1f8b107324faed81acd7ca76858b7bd97c7c8a`
- Hosted run: [iOS unsigned IPA #6](https://github.com/todaysday/codex-app-mobile/actions/runs/45036419930)
- Artifact: [CodexMobile-unsigned-6](https://github.com/todaysday/codex-app-mobile/actions/runs/45036419930/artifacts/14759824839)
- Protocol reference: official Codex `rust-v0.171.0`, source `ccf9be8cc458bd6b8336fe84d68d8893f2691a5e`

## Portable checks

`make validate` passed on 2026-11-22. It checked all 48 Swift source memberships, shared schemes, pinned dependencies, app identity, privacy declarations, Release transport configuration, workflow structure, bundled notices, and the three OpenSpec changes. The specifications contain 41 requirements and 96 scenarios. All 8 Python build/packaging tests passed. `git diff --check` was clean.

These checks do not compile Swift. They complement the hosted Xcode checks below.

## Hosted Xcode checks

The combined suite passed on 2026-11-22 using **Xcode 26.2, build 17C52**, on an **iPhone 16 / iOS 18.6** simulator. The actual XCTest log reports **196 tests, 0 failures** and `TEST SUCCEEDED`. The subsequent unsigned **iPhoneOS Release** build and artifact upload also passed.

| Test group | Cases | Result |
| --- | ---: | --- |
| App navigation and retained state | 3 | Passed |
| Endpoint, authentication, and credential isolation | 12 | Passed |
| ChatGPT Web behavior and profile isolation | 12 | Passed |
| Retained upstream Codex tests | 85 | Passed |
| Scoped drafts and immutable submission routing | 13 | Passed |
| Goals, thread controls, and event ownership | 18 | Passed |
| Native controls and child inspection | 6 | Passed |
| Official protocol and lifecycle fixtures | 31 | Passed |
| Permission, command, and user-input requests | 16 | Passed |
| **Total XCTest** | **196** | **0 failures** |

The 8 Python build/packaging tests also passed in the hosted run. Diagnostics are available in its `ios-diagnostics-6-1` artifact. These fixtures use controlled local data and do not establish live compatibility with a particular VPS or account.

## Downloaded artifact verification

The Actions distribution and diagnostic ZIPs were downloaded. Their SHA-256 values matched the hashes reported by GitHub. The IPA was then checked independently against `SHA256SUMS`, `build-info.json`, and the packaged `Info.plist`.

| Property | Observed value |
| --- | --- |
| IPA | `CodexMobile-unsigned.ipa` |
| Size | 14,385,671 bytes |
| Version/build | 1.0 (6) |
| Bundle identifier | `dev.todaysday.codexmobile` |
| Minimum OS | iOS 18.0 |
| Architecture | arm64 |
| Platform | iPhoneOS |
| Signing | Unsigned; no embedded provisioning profile or code-signature directory |
| Source commit | `0a1f8b107324faed81acd7ca76858b7bd97c7c8a` |
| IPA SHA-256 | `ad1f6f51734c3497f107c5daae46c2675a065add9f66f5adc0ad4eb3973b5673` |

Archive integrity, application executable permissions, privacy manifest, project/donor/official Codex notices, and the pinned SwiftPM dependency notices were verified. The distribution includes the IPA, `SHA256SUMS`, `build-info.json`, and `INSTALL.txt`. It requires signing through the user's installation tool, such as SideStore.

## Live acceptance

The actual VPS version, live compatible goal/subagent/control behavior, the intended ChatGPT login and Pro/web features, independent accounts, SideStore installation, and signature refresh have **not** been tested on the user's iPhone. See [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md), including C01–C12 for the new official controls and composer behavior. No second VPS server was started and no server-side account was reauthorized during development.
