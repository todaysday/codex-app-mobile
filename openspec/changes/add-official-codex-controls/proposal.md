# Add current official Codex controls

## Why

The retained iPhone client already speaks App Server, but its thread listing stops at one page, its context counter expects an older payload, and several current server capabilities are not reachable from the workbench. The user asked to inspect the current official Codex and then explicitly authorized taking all applicable capabilities now. That instruction supersedes the earlier sequencing that postponed Goal Mode and subagents until ChatGPT Web device acceptance.

## What Changes

- Align session discovery, history loading, reconnect, active-turn tracking, and token counters with the pinned official stable protocol.
- Add persisted thread goals, structured subagent navigation, server-side thread naming, manual compaction, and confirmed conversation-history revert.
- Preserve existing steering, interrupt, approvals, user input, model selection, archive/fork, SSH, and Git features while correcting current protocol gaps.
- Display server-driven plan/diff updates and available model metadata.
- Recognize supported, unavailable, and experimental operations without inventing server methods or changing the existing VPS service.

## Impact

Affected capabilities: `remote-session-compatibility`, `thread-goals-and-controls`, `subagent-workbench`, `request-interactions`, and `live-workbench-metadata`.

Affected code: App Server DTOs/parsing/state, the existing session workbench and request sheet, focused tests, and documentation. There is no new backend and no shared authentication with ChatGPT Web.

The implementation baseline is official stable `rust-v0.171.0`, commit `ccf9be8cc458bd6b8336fe84d68d8893f2691a5e`. Public main `cf3ff1530d821ec2d26452da4971d8e3e7d18d25` and the installed `0.172.0-alpha.2` generator were inspected separately; neither is represented as the current stable release. Source contracts and exact references are in [design.md](design.md).

## Authorization and limits

Specification and implementation are authorized by the user's latest instruction on 2026-11-22. Implementation may proceed before physical ChatGPT/SideStore acceptance; those independent gates remain required before declaring the combined product accepted.

This change adds client controls for already-running compatible servers. It does not upgrade, reauthorize, replace, or spawn the user's VPS process. Unknown methods remain visibly unavailable. It does not add arbitrary client-side tool execution, account administration, realtime audio, a new cloud relay, or the Rust TUI.

## Acceptance

Protocol fixtures, existing tests, and macOS compilation must pass. User-facing controls must be reachable, correctly scoped to the selected thread, and honestly report unsupported operations. Live acceptance must separately record the actual VPS version, a CLI/desktop-created thread, a real parent/child session, and the final IPA. The existence of a schema alone does not prove live compatibility.

