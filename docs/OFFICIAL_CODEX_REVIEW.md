# Official Codex source review

Reviewed on **2026-11-22** for [todaysday/codex-app-mobile](https://github.com/todaysday/codex-app-mobile).

The useful material is the official App Server protocol and its lifecycle behavior. The existing SwiftUI client already implements core operations; importing the Rust TUI would not produce an iPhone interface.

## Versions inspected

| Surface | Observed revision | Meaning |
| --- | --- | --- |
| Latest public stable | [rust-v0.171.0](https://github.com/openai/codex/releases/tag/rust-v0.171.0), published 2026-11-20 00:44 UTC | Implementation baseline |
| Stable source | [ccf9be8cc458bd6b8336fe84d68d8893f2691a5e](https://github.com/openai/codex/commit/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e) | Resolved through the annotated release tag |
| Public main | [cf3ff1530d821ec2d26452da4971d8e3e7d18d25](https://github.com/openai/codex/commit/cf3ff1530d821ec2d26452da4971d8e3e7d18d25), 2026-11-22 08:27 UTC | Development branch, separately inspected |
| Installed CLI | `codex-cli 0.172.0-alpha.2` | Local prerelease; generated experimental TS for inspection without starting a server |
| Mobile baseline | [6ddaa25d6f69288cd8a4e09c1cf8eaec9a89a511](https://github.com/todaysday/codex-app-mobile/commit/6ddaa25d6f69288cd8a4e09c1cf8eaec9a89a511) | Existing client before this implementation |
| User's VPS | Not queried in this review | Requires its own live compatibility evidence |

[Official documentation](https://developers.openai.com/codex/app-server/) was checked against pinned stable Rust protocol source. All source links below use the release commit, not floating main. Main has further development changes, including path representation and additional experimental fields; their existence is not a reason to require prerelease servers.

The stable release already includes remote exec against an existing App Server and a TUI subagent transcript sidebar. These are useful precedents for reconnect and child-message inspection, not a requirement to copy terminal rendering.

## Existing client versus useful additions

“Missing” means absent from the audited baseline. Actual completion is tracked in [official-controls tasks](../openspec/changes/add-official-codex-controls/tasks.md).

| Area | Existing mobile behavior | Take from official now | Compatibility |
| --- | --- | --- | --- |
| Sessions | Start/read/resume/fork/archive, selected-thread reattach | All-source cursor pagination, loaded status, paginated history | Default source filter hides noninteractive sessions; new history paths need legacy fallback |
| Goals | No goal model/panel | Get/set/clear, counters, status, user mutation origin | Stable methods in 0.171; isolate unsupported older servers |
| Subagents | Generic records without lineage | Parent/ancestor queries, names/roles/status, structured message/action/tool cards from original item payloads | Relationship queries and direct-input capability are experimental |
| Steering | Correct `expectedTurnId` request already exists | Recover active turn from snapshots; preserve precondition | Do not create a new turn merely to attach |
| Interrupt | Request exists | Wait for matching completion after request acceptance | Optimistic clearing of active state needs correction |
| Approvals | Command/file choices, amendments, resolved-request removal | Human-command restrictions and explicit permission grant/deny profiles | Scope and profile response differ from command decisions |
| User input | Questions/options and answers exist | Header, secret/other flags, blocking state, literal answers | Preserve request identity and reject resolved submissions |
| Token usage | Flat legacy-style field lookup | Nested latest and total breakdowns, nullable context window | Confirmed compatibility defect |
| Models | Pagination, reasoning/default/upgrade/availability | Description, modalities, multi-agent version, service tiers | New metadata must be optional; no fixed model names |
| Plan/diff | Plan text streaming, SSH working-tree diff | Structured plan and current aggregate turn diff | Keep these observations distinct from SSH Git |
| Maintenance | Fork/archive exist | Rename, compact, confirmed history revert | Current API is `thread/revert`; rollback was removed |
| Files/worktrees | SSH path and Git operations exist | Workspace text/image/PDF previews and Git worktree list/create/open/remove through the existing App Server | Full-file reads only, 2 MiB preview cap, verified `command/exec` argv rather than a native `worktree/*` RPC |

## Confirmed protocol gaps

### Session discovery and active work

The baseline [list/read implementation](https://github.com/todaysday/codex-app-mobile/blob/6ddaa25d6f69288cd8a4e09c1cf8eaec9a89a511/CodexAppMobile/Features/Orchestration/AppServerClient.swift#L345-L383) reads one page of 100 and discards the continuation. An omitted or empty source filter selects interactive sources, not all sessions. Official [list fields](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L1451-L1544) and [source kinds](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L1592-L1617) provide the remedy.

Read does not subscribe; resume attaches. Loaded IDs do not establish active generation. The [status/read contracts](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L1762-L1826) distinguish not-loaded, idle, active, and error. [Turn pagination](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L1906-L1935) avoids unbounded full-history reads on modern persistent threads.

Reading a CLI-created saved thread alone does not prove that a separate CLI process and this App Server share one live turn. Live multi-client control must use the same compatible server/runtime; do not start another daemon to simulate attachment.

### Usage and requests

Official [token usage](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L2148-L2237) is `{total,last,modelContextWindow}`. The baseline flat lookup can produce empty counters from valid modern events. Latest reported totals and cumulative consumption remain distinct; a raw latest-total/window ratio is an estimate, not exact parity with the TUI's baseline-adjusted percentage.

[Command kind](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/item.rs#L1674-L1753) separates commands, stdin, and human checkpoints. Human checkpoints allow only accept/decline/cancel and require the matching initialization capability.

[Permission approval](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/permissions.rs#L773-L808) returns a granted profile and turn/session scope. Empty permissions deny access. Unknown shapes must not be granted implicitly.

[User input](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/item.rs#L1866-L1945) carries secret, other-answer, header, and blocking metadata. The baseline drops these fields and splits free-form answers on commas, changing literal answers. Current response handling must preserve actual user text.

## Goal, subagent, and maintenance contracts

[Goal methods are stable](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/common.rs#L651-L664). Their [payloads](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L835-L947) distinguish omitted budget from explicit null. Explicit UI mutations send `origin:"user"`; displaying a panel is not a mutation. The official states are active, paused, blocked, usageLimited, budgetLimited, and complete.

[Thread metadata](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/thread_data.rs#L203-L298) distinguishes parent, fork, and attached-thread relationships. Build subagent navigation from these fields, with mutually exclusive parent/ancestor filters. A child with `canAcceptDirectInput:false` remains readable but cannot accept direct input.

[Revert](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L1331-L1359) uses `thread/revert {threadId,beforeTurnId}`. It removes that turn and later conversation history without reverting local files. Returned `thread.turns` is empty: rehydrate retained history from the official cursors. The current documentation explicitly states that `thread/rollback` is removed.

The implementation review also checked two lifecycle details beyond the DTOs. [GoalService.clear_thread_goal](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/ext/goal/src/api.rs#L296-L348) returns whether a goal row was deleted; `cleared:false` means no goal existed, while failures return errors. The [App Server handler](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server/src/request_processors/thread_goal_processor.rs#L275-L321) emits a cleared notification only for `true`, so either successful boolean response must invalidate unchanged cached goal state. Manual compaction [emits the new turn start before running compaction](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/core/src/tasks/compact.rs#L27-L106); the [event handler](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server/src/bespoke_event_handling.rs#L174-L201) forwards it as `turn/started`. This supports rejecting older-turn metadata while waiting for actual compaction completion. Local review also found that RPC IDs alone cannot identify a pending approval across reconnects or replacement requests: each arrival needs its own identity, checked by both the presented sheet and response sender before granting access.

[Structured plan/diff events](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/turn.rs#L623-L657) and [model metadata](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/model.rs#L53-L184) are suitable native workbench additions. Aggregate diffs replace earlier snapshots; they are not appended as text deltas.

[Filesystem reads](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/fs.rs) supply the implemented preview: `fs/readDirectory`, `fs/getMetadata`, and `fs/readFile`. Metadata has type/symlink flags but no byte size; readFile returns the full base64 file without range/limit parameters. The client checks size through bounded `wc -c -- <path>`, then validates the base64/decoded size against 2 MiB and preserves a finite 4 MiB WebSocket frame cap.

[command/exec](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/command_exec.rs) accepts `command` as argv, `cwd`, `timeoutMs`, and `outputBytesCap`, returning buffered `exitCode`, `stdout`, and `stderr`. The implemented worktree manager uses these fields for Git list/create/status/remove and never supplies a policy override or shell interpolation. Its porcelain parser handles NUL records and significant whitespace. Removal refreshes the list, blocks protected worktrees and local files, and omits force. See the [workspace design](../openspec/changes/add-workspace-files-and-worktrees/design.md) for exact requests and limits.

[Official item variants](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/item.rs) now remain available as raw payloads through history decoding. Native child cards use real fields for commands, file diffs, MCP/dynamic tools, collaboration, and reported reasoning summaries; unknown variants show bounded structured details. The old conversion's assumption that every `content` field was user input was incorrect for reasoning items and has been corrected.

## Implementation decision

The user's instruction to take applicable official capabilities now supersedes the old P1-after-device-acceptance sequencing. [The active proposal](../openspec/changes/add-official-codex-controls/proposal.md) covers session correctness, goals, subagents, current thread controls, requests, and observations.

Optional operations fail per feature. They do not authorize upgrading or replacing the user's VPS, merging accounts, adding arbitrary client tool execution, or a new relay/backend. Real ChatGPT login, independent accounts, SideStore installation/refresh, and the actual VPS protocol still need their separate live checks.

