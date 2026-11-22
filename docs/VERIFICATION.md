# Build and verification record

This record separates source validation, hosted iOS verification, and physical-device acceptance.

## Verified review-fix build

- Repository: `todaysday/codex-app-mobile`
- Code commit: `805ebe270b65f85e641a725158ad6caec881c94f`
- Hosted run: [iOS unsigned IPA #17](https://github.com/todaysday/codex-app-mobile/actions/runs/45049173299)
- Artifact: [CodexMobile-unsigned-17](https://github.com/todaysday/codex-app-mobile/actions/runs/45049173299/artifacts/14764364090)
- Protocol reference: official Codex `rust-v0.171.0`, source `ccf9be8cc458bd6b8336fe84d68d8893f2691a5e`

This build includes an extensible named web-profile registry with explicit Settings Add/Rename/Delete, structured subagent cards, WSS-only hosts, workspace file previews, and worktree tools. Profiles are not limited to two. The original WebKit store identifier is preserved for migration; clear/delete operations affect only the captured profile. Initial child history can load while a newly mounted view is briefly inactive; subsequent automatic reads require the foreground.

## Portable checks

`make validate` passed on 2026-11-22. It checked all 60 Swift source memberships, shared schemes, pinned dependencies, app identity, privacy declarations, Release transport configuration, workflow structure, bundled notices, and seven OpenSpec changes. The specifications contain 64 requirements and 163 scenarios. All 8 Python build/packaging tests passed. `git diff --check` was clean.

These checks do not compile Swift. They complement the hosted Xcode checks below.

## Hosted Xcode checks

The combined suite passed on 2026-11-22 using **Xcode 26.2, build 17C52**, on an **iPhone 16 / iOS 18.6** simulator. The downloaded XCTest log reports **264 tests, 0 failures** and `TEST SUCCEEDED`; all 264 test cases have individual pass records. The subsequent unsigned **iPhoneOS Release** build and artifact upload also passed.

| Test group | Cases | Result |
| --- | ---: | --- |
| App navigation and retained state | 3 | Passed |
| Endpoint, authentication, and credential isolation | 12 | Passed |
| Named profiles, migration, cookies, clearing and deletion | 13 | Passed |
| ChatGPT Web navigation and browser behavior | 12 | Passed |
| Retained upstream Codex tests | 85 | Passed |
| Scoped drafts and immutable submission routing | 13 | Passed |
| Goals, thread controls, and event ownership | 18 | Passed |
| Native controls, child inspection, and scene lifecycle | 7 | Passed |
| Structured child history, presentation, and refresh races | 17 | Passed |
| File previews, worktree commands, and stale-operation guards | 26 | Passed |
| WSS-only hosts, optional SSH, and project registration | 11 | Passed |
| Official protocol and lifecycle fixtures | 31 | Passed |
| Permission, command, and user-input requests | 16 | Passed |
| **Total XCTest** | **264** | **0 failures** |

The 8 Python build/packaging tests also passed in the hosted run. Diagnostics are available as [ios-diagnostics-17-1](https://github.com/todaysday/codex-app-mobile/actions/runs/45049173299/artifacts/14765265795). Profile fixtures add four profiles, retain three mounted browsers, and exercise independent same-origin cookie sessions; they do not sign into real ChatGPT accounts. The protocol and workspace fixtures use controlled responses and do not establish live compatibility with a particular VPS.

## Downloaded artifact verification

The Actions distribution and diagnostics ZIPs were downloaded. Their SHA-256 values matched the hashes reported by GitHub. The IPA was then checked independently against `SHA256SUMS`, `build-info.json`, and the packaged `Info.plist`.

| Property | Observed value |
| --- | --- |
| IPA | `CodexMobile-unsigned.ipa` |
| Size | 14,771,785 bytes |
| Version/build | 1.0 (17) |
| Bundle identifier | `dev.todaysday.codexmobile` |
| Minimum OS | iOS 18.0 |
| Architecture | arm64 |
| Platform | iPhoneOS |
| Signing | Unsigned; no embedded provisioning profile or code-signature directory |
| Source commit | `805ebe270b65f85e641a725158ad6caec881c94f` |
| IPA SHA-256 | `69963248e84252ab92c5f7f522bd4025b1b948326c7044096c355c52e36eef1c` |

Archive integrity, application executable permissions and Mach-O architecture, privacy manifest, project/donor/official Codex notices, and the pinned SwiftPM dependency notices were verified. The distribution includes the IPA, `SHA256SUMS`, `build-info.json`, and `INSTALL.txt`. It requires signing through the user's installation tool, such as SideStore.

| Downloaded ZIP | SHA-256 |
| --- | --- |
| `CodexMobile-unsigned-17.zip` | `7369d54bd62bb62b22ad45c62a2af37985404507e78ed3b475f323ff2a4e3329` |
| `ios-diagnostics-17-1.zip` | `14a3cd53639bc71628972ae0d840699c97fa7e8bbf6f9db74d57b2938d934ac2` |

## Resolved verification findings

Run #13 exposed a Swift 6 `Sendable` requirement after structured JSON was preserved in thread history. The JSON value enum now declares compiler-checked `Sendable` conformance; concurrency checking remains enabled. Run #14 exposed three assertions in one mounted child-inspection UI test because its initial scene was inactive. Initial loading now works during that transient state. Run #15 passed before the additional background-transition guard and mounted regression test included in the verified build above. Run #16 passed the child lifecycle regression but exposed a cold WebKit fixture: process startup exceeded the bounded page-stop timeout, so reset correctly preserved the profile and its data. The profile-clear test now mounts its target browser and waits for a local document before requesting a successful reset; production timeout and failure behavior are unchanged.

The previous 196-test baseline and build 6 remain traceable in [run #6](https://github.com/todaysday/codex-app-mobile/actions/runs/45036419930); they are superseded by this candidate.

## Live acceptance and implementation limits

The actual VPS version, live compatible goal/subagent/control behavior, intended ChatGPT login and Pro/web features, independent real accounts, SideStore installation, and signature refresh have **not** been tested on the user's iPhone. See [DEVICE_ACCEPTANCE.md](DEVICE_ACCEPTANCE.md), including R01–R11 for the profile/workspace review fixes. No second VPS server was started and no server-side account was reauthorized during development.

File previews are read-only, capped at 2 MiB, and do not follow symbolic links; the inspected filesystem RPC returns full files. Worktrees support list/create/open/confirmed clean removal, with no force, branch deletion, move, lock/unlock, or prune. These bounds are documented in the [roadmap](ROADMAP.md).
