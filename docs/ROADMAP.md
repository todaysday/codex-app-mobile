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
| Subagents | Reported parent relationships, rich message/action/tool/file cards, active child refresh, return to parent, input restrictions | [Rich history tasks](../openspec/changes/add-rich-subagent-messages/tasks.md) |
| Thread controls | Rename, confirmed manual compaction, idle persistent-history revert using `thread/revert` | [Task 8](../openspec/changes/add-official-codex-controls/tasks.md) |
| Requests | Current command/human choices, permission grant/deny scope, secret/other/blocking input | [Task 9](../openspec/changes/add-official-codex-controls/tasks.md) |
| Live workbench | Structured server plan and aggregate turn diff; retain upstream SSH Git/diff | [Task 10](../openspec/changes/add-official-codex-controls/tasks.md) |
| Web profiles | Settings explicitly adds named independent profiles, switches, renames and deletes them; existing login migration; no fixed two-profile limit | [Profile tasks](../openspec/changes/add-independent-chatgpt-profiles/tasks.md) |
| Host setup | WSS-only connection with optional SSH fallback and capability-aware SSH controls | [Host tasks](../openspec/changes/allow-app-server-only-hosts/tasks.md) |
| File previews | Workspace browser; text/code, image and PDF previews up to 2 MiB; official full-file RPC with size/type checks | [Workspace tasks](../openspec/changes/add-workspace-files-and-worktrees/tasks.md) |
| Worktrees | List, create a new branch/worktree, open as a project, confirmed removal of an eligible clean worktree through Git argv over `command/exec` | [Workspace tasks](../openspec/changes/add-workspace-files-and-worktrees/tasks.md) |

These controls have native UI and protocol implementations. [Verification](VERIFICATION.md) records the last completed hosted run; the current review fixes require a new run before their IPA is considered verified. The linked checklists retain separate live-server and physical-device acceptance gates. [Thread-scoped drafts](../openspec/changes/fix-thread-scoped-composer/proposal.md) preserve input and immutable submission targets across navigation and reconnects.

## Remaining scope

- **Files:** files larger than 2 MiB, symbolic-link navigation, arbitrary binary formats, editing, and streaming/ranged reads are outside the preview implementation. The official full-file RPC has no verified range/limit parameter.
- **Worktrees:** move, lock/unlock, prune, force removal, and branch deletion are not included. The implemented manager preserves existing SSH Git functionality and does not invent a `worktree/*` RPC.
- **Notifications:** improve useful local presentation within iOS limits. A remote push service or guaranteed background socket is a separate architecture.

## Compatibility and acceptance

Goal methods are stable in the inspected release. Parent/ancestor filters and some metadata are experimental. Optional-feature rejection must preserve the existing server and ordinary chat; the app must not start another server to make a control appear supported.

The final IPA still needs [device acceptance](DEVICE_ACCEPTANCE.md): standalone SideStore installation, real ChatGPT login, account isolation, existing VPS operation, and signature refresh. These checks no longer block writing the authorized Codex controls; they remain necessary evidence for product acceptance.
