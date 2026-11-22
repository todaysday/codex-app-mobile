# Implementation tasks

Status is evidence-based. Source implementation, CI success, and physical acceptance are separate gates. Unchecked items must not be represented as completed in release notes.

- [x] 1. Inspect the upstream client and WebView donor, record revisions/licenses, and preserve the supplied handoff.
- [x] 2. Validate this proposal and its four capability specifications against the handoff and current source structure.
- [x] 3. Add the stable Codex/ChatGPT/Settings shell while retaining upstream Codex state and behavior.
- [x] 4. Implement the dedicated persistent ChatGPT browser, safe navigation controls, progress/errors, and Safari fallback.
- [x] 5. Implement confirmed, isolated website-data clearing and permission handling; preserve both Codex and other browser profiles.
- [x] 6. Preserve secure full App Server endpoints and support required proxy authentication using Keychain without exposing secrets.
- [x] 7. Wire the new files, resources, app identity, and privacy declarations into the actual Xcode targets; preserve licensing notices.
- [x] 8. Add and run meaningful browser/isolation/endpoint tests and retain existing Codex tests; record the environment and results.
- [x] 9. Implement hosted macOS scheme inspection, simulator checks, unsigned device build, artifact validation, and IPA upload.
- [x] 10. Complete a successful GitHub Actions run and verify its downloadable unsigned IPA and provenance metadata.
- [x] 11. Review README, setup instructions, upstream attribution, and the device acceptance checklist against the implemented behavior.
- [ ] 12. On the requested iPhone, verify real ChatGPT login/entitlements, persistent independent accounts, Codex connection to the existing VPS, standalone SideStore installation, and a successful signature refresh.

## Physical acceptance gate

Task 12 requires the user's existing server and account plus the physical device. See [DEVICE_ACCEPTANCE.md](../../../docs/DEVICE_ACCEPTANCE.md). An automatic unit test, WebView loading the login page, or a working Safari fallback does not satisfy this gate.

## Follow-up ordering

The user authorized implementing Goal Mode, subagent navigation, and applicable current official controls immediately on 2026-11-22. They are specified and tracked separately in [add-official-codex-controls](../add-official-codex-controls/tasks.md) and [fix-thread-scoped-composer](../fix-thread-scoped-composer/tasks.md). Their implementation does not waive this MVP's physical acceptance gate.

## Hosted verification

Code commit `0a1f8b107324faed81acd7ca76858b7bd97c7c8a` passed [macOS CI #6](https://github.com/todaysday/codex-app-mobile/actions/runs/45036419930): 196 XCTest cases, 8 Python tooling tests, and the unsigned iPhoneOS Release build. The downloaded IPA and provenance were independently checked. See [VERIFICATION.md](../../../docs/VERIFICATION.md). Physical-device and actual-VPS acceptance remain open.
