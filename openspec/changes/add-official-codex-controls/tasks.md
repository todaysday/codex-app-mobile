# Implementation tasks

The user's 2026-11-22 authorization permits this work now; the previous P1/P2-after-device-test order does not block implementation. All live acceptance gates remain evidence-based.

- [x] 1. Inspect installed official CLI, pin current stable release and public main separately, and compare the real mobile client against source contracts.
- [x] 2. Specify the applicable controls and compatibility behavior with pinned references and scenarios.
- [x] 3. Implement complete source-aware thread discovery and cursor handling, preserving current metadata on failed refresh.
- [x] 4. Reconcile loaded/read/resume history, active turns, steering, interrupt, and late terminal events.
- [x] 5. Parse official nested token usage and distinguish latest context from cumulative usage.
- [x] 6. Add Goal get/set/clear state, notifications, and reachable goal controls with user-origin semantics.
- [x] 7. Add parent/child metadata, experimental relationship queries, status, and child transcript navigation without creating sessions.
- [x] 8. Add rename, manual compaction, and confirmed idle persistent-history revert with correct history reload.
- [x] 9. Complete current command, permission, and user-input request semantics and resolution handling.
- [x] 10. Add structured turn plan/diff state and surface verified model metadata in the workbench.
- [x] 11. Add and run meaningful protocol/lifecycle fixture tests, keep upstream tests, and pass macOS compilation.
- [x] 12. Update the research report, capability status, and actual user-facing controls to match the finished implementation.
- [ ] 13. Verify the final IPA against the actual existing VPS version, a CLI/desktop-created session, a child session, and relevant control actions; record remaining device gates separately.

## Delivery boundaries

A source implementation or fixture pass is not a live compatibility pass. Unsupported server methods remain clearly unavailable. No task authorizes replacing the user's server, logging out its account, starting another daemon, or changing ChatGPT Web credentials.


## Hosted verification

Code commit `0a1f8b107324faed81acd7ca76858b7bd97c7c8a` passed [macOS CI #6](https://github.com/todaysday/codex-app-mobile/actions/runs/45036419930): 196 XCTest cases, 8 Python tooling tests, and the unsigned iPhoneOS Release build. The downloaded IPA and provenance were independently checked. See [VERIFICATION.md](../../../docs/VERIFICATION.md). Physical-device and actual-VPS acceptance remain open.
