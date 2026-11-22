# Codex capability roadmap

Updated **2026-11-22** after the user authorized implementing applicable capabilities from the current official Codex immediately.

## Implemented source and verification

The earlier handoff put Goal Mode, subagents, and workbench additions after ChatGPT Web device acceptance. The user's later instruction supersedes that implementation order. Work now follows [add-official-codex-controls](../openspec/changes/add-official-codex-controls/proposal.md); source completion, macOS CI, live-server compatibility, and iPhone acceptance remain separate gates.

The baseline is official stable [Codex 0.171.0](https://github.com/openai/codex/releases/tag/rust-v0.171.0), source `ccf9be8cc458bd6b8336fe84d68d8893f2691a5e`. The [source review](OFFICIAL_CODEX_REVIEW.md) distinguishes stable, public main, and the installed prerelease.

| Slice | Included behavior | Evidence/status |
| --- | --- | --- |
| Existing sessions | Source-aware cursor pagination, loaded/read/resume, active-turn recovery, proper steer/interrupt lifecycle | [Tasks 3–4](../openspec/changes/add-official-codex-controls/tasks.md) |
| Usage/models | Nested latest/total usage, nullable context window, optional current model metadata | [Tasks 5 and 10](../openspec/changes/add-official-codex-controls/tasks.md) |
| Goals | Read/set/clear, budget/status controls, server counters, events, explicit user origin | [Task 6](../openspec/changes/add-official-codex-controls/tasks.md) |
| Subagents | Reported parent relationships, child status/messages, return to parent, input restrictions | [Task 7](../openspec/changes/add-official-codex-controls/tasks.md) |
| Thread controls | Rename, confirmed manual compaction, idle persistent-history revert using `thread/revert` | [Task 8](../openspec/changes/add-official-codex-controls/tasks.md) |
| Requests | Current command/human choices, permission grant/deny scope, secret/other/blocking input | [Task 9](../openspec/changes/add-official-codex-controls/tasks.md) |
| Live workbench | Structured server plan and aggregate turn diff; retain upstream SSH Git/diff | [Task 10](../openspec/changes/add-official-codex-controls/tasks.md) |

These controls now have native UI and protocol implementations. Source work is complete; the linked checklists separately record macOS tests and live-device acceptance. [Thread-scoped drafts](../openspec/changes/fix-thread-scoped-composer/proposal.md) also preserve input and immutable submission targets across navigation and reconnects.

## Additional supported foundations

- **Read-only file previews:** stable filesystem reads are verified in the source review. A complete preview needs size limits, decoding/content handling, and navigation; the full-file RPC has no verified range/limit parameter.
- **Worktrees:** preserve existing SSH Git functionality. Any further mutation needs a verified contract; no hypothetical `worktree/*` method is assumed.
- **Notifications:** improve useful local presentation within iOS limits. A remote push service or guaranteed background socket is a separate architecture.

## Compatibility and acceptance

Goal methods are stable in the inspected release. Parent/ancestor filters and some metadata are experimental. Optional-feature rejection must preserve the existing server and ordinary chat; the app must not start another server to make a control appear supported.

The final IPA still needs [device acceptance](DEVICE_ACCEPTANCE.md): standalone SideStore installation, real ChatGPT login, account isolation, existing VPS operation, and signature refresh. These checks no longer block writing the authorized Codex controls; they remain necessary evidence for product acceptance.
