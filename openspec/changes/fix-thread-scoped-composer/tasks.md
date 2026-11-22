# Tasks

- [x] 1. Verify the upstream release and demonstrate the existing selection-after-await race.
- [x] 2. Specify draft scopes, immutable routing, and recovery behavior before implementation.
- [x] 3. Add the application-owned in-memory draft store and view scope lifecycle.
- [x] 4. Capture request context before suspension, reconcile reconnect state, and prevent unrelated selection changes.
- [x] 5. Recover failed submissions in their source scope while preserving newer input and context tokens.
- [x] 6. Run scope/routing/recovery tests and the combined macOS build.
- [ ] 7. Record device acceptance for switching threads during connection and submission.

## Hosted verification

Code commit `0a1f8b107324faed81acd7ca76858b7bd97c7c8a` passed [macOS CI #6](https://github.com/todaysday/codex-app-mobile/actions/runs/45036419930): 196 XCTest cases, 8 Python tooling tests, and the unsigned iPhoneOS Release build. The downloaded IPA and provenance were independently checked. See [VERIFICATION.md](../../../docs/VERIFICATION.md). Physical-device and actual-VPS acceptance remain open.
