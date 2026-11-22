# Design and pinned source contracts

## Evidence baseline

- Current stable: [0.171.0 release](https://github.com/openai/codex/releases/tag/rust-v0.171.0), published 2026-11-20; source commit `ccf9be8cc458bd6b8336fe84d68d8893f2691a5e`.
- Inspected public main on 2026-11-22: [cf3ff1530d821ec2d26452da4971d8e3e7d18d25](https://github.com/openai/codex/commit/cf3ff1530d821ec2d26452da4971d8e3e7d18d25).
- Installed local CLI: `codex-cli 0.172.0-alpha.2`. Its experimental TS generator was used for inspection without starting a server. Public stable source, not this prerelease executable, is the compatibility baseline.
- [Official App Server documentation](https://developers.openai.com/codex/app-server/) describes current behavior; pinned source resolves differences or abbreviated examples.

| Contract | Pinned stable source |
| --- | --- |
| Goal model, statuses, origin, nullable budget | [thread.rs L835-L947](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L835-L947) |
| Goal methods are not experimental | [common.rs L651-L664](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/common.rs#L651-L664) and [tests L4565-L4633](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/common.rs#L4565-L4633) |
| Thread filters and experimental relationship filters | [thread.rs L1451-L1544](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L1451-L1544) |
| Loaded threads, statuses, metadata-only reads | [thread.rs L1762-L1826](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L1762-L1826) |
| Turn-history pagination | [thread.rs L1906-L1935](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L1906-L1935) |
| Parent/fork metadata and direct-input capability | [thread_data.rs L203-L298](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/thread_data.rs#L203-L298) |
| Revert request and history cursors | [thread.rs L1331-L1359](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L1331-L1359) |
| Steering precondition | [turn.rs L328-L363](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/turn.rs#L328-L363) |
| Token-usage payload | [thread.rs L2148-L2237](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L2148-L2237) |
| Command approval and user input | [item.rs L1674-L1797](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/item.rs#L1674-L1797), [L1866-L1945](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/item.rs#L1866-L1945) |
| Permission approval | [permissions.rs L773-L808](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/permissions.rs#L773-L808) |
| Model catalogue | [model.rs L53-L184](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/model.rs#L53-L184) |
| Streamed aggregate diff and structured plan | [turn.rs L623-L657](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/turn.rs#L623-L657) |

## Existing integration and ownership

Extend the current AppServerClient and workbench; do not create a parallel client. Preserve existing thread start/read/resume/fork/archive, turn start/steer/interrupt, request routing, model catalogue pagination, collaboration modes, account limits, SSH Terminal, and SSH Git/diff.

New data is keyed by thread ID, and turn-owned state also carries the turn ID. Stale responses from a prior selected host or disconnected transport must not overwrite a new host's data. Back navigation from a child restores the parent selection. Reading a child must not create a thread, start a turn, change the parent's goal, or automatically archive a session.

## Discovery and history

Ordinary `thread/list` omits noninteractive sources unless `sourceKinds` is explicit. Supported values are `cli`, `vscode`, `exec`, `appServer`, `subAgent`, `subAgentReview`, `subAgentCompact`, `subAgentThreadSpawn`, `subAgentOther`, and `unknown`. Omitted or empty `sourceKinds` is not an all-sources query.

Follow `nextCursor` without changing query filters; deduplicate IDs. Each page is bounded. Finish at a null cursor or preserve an explicit user-visible load-more state. Repeated cursors, failed pages, and cancellation must not create an endless loop or silently erase existing history.

`thread/loaded/list` supplies loaded IDs with its own cursor. Stored history and loaded state are different. `thread/read` does not subscribe; `thread/resume` attaches. New persistent threads use paginated history. Prefer metadata plus `thread/turns/list` with `itemsView:"full"` for usable messages; preserve legacy full-history fallback only when the server lacks the newer method. An empty summary-mode items array is not proof of an empty conversation.

Retain returned `historyMode`, `parentThreadId`, `forkedFromId`, `status`, and optional `canAcceptDirectInput`. Relationship filters `parentThreadId` and `ancestorThreadId` require experimental opt-in and are mutually exclusive. `attachedToThreadId` represents another relationship and must not be treated as a subagent parent.

## Goals and thread actions

Goal methods are stable in the inspected release. Goal fields are `threadId`, `objective`, `status`, `tokenBudget`, `tokensUsed`, `timeUsedSeconds`, `createdAt`, and `updatedAt`. Status values are `active`, `paused`, `blocked`, `usageLimited`, `budgetLimited`, and `complete`. Get returns a nullable `goal`; set returns `goal`; clear returns `cleared`.

Set/clear carry `origin:"user"` only for explicit user actions. A missing budget preserves it; explicit null removes it. Do not update goals merely because a view appeared. `thread/goal/updated` and `thread/goal/cleared` update the matching thread.

Rename uses `thread/name/set {threadId,name}`. Compaction uses `thread/compact/start {threadId}` and completes asynchronously. Revert uses `thread/revert {threadId,beforeTurnId}`, removing that turn and later conversation history without reverting files. Current `thread/rollback` has been removed; do not call it. Revert requires a loaded persistent paginated thread and must rehydrate retained history from its returned cursors because `thread.turns` is empty. Confirm compaction/revert with their real effect and apply idle guards; failed requests leave local history intact.

## Turn reconciliation and requests

Rebuild active-turn state from read/resume history and status snapshots after reconnect. `turn/steer` requires the exact `expectedTurnId`; `turn/interrupt` acceptance does not establish completed cancellation. Keep the turn active or stopping until a matching terminal event/snapshot. A late completion for an older turn must not clear a newer turn or its approval.

Respect `canAcceptDirectInput:false`. A missing/null flag is unknown, not permission to rewrite the server state. Preserve normal compatibility behavior for older servers, handle server rejection honestly, and make no automatic second turn when attaching.

Existing command/file decisions and `serverRequest/resolved` routing remain. Extend missing request metadata: command `kind`, question `header`, `isSecret`, `isOther`, and `isBlocking`. Human-command checkpoints allow only accept/decline/cancel, never session-wide approval. Advertise `requiredHumanApproval` only if that flow is supported. Permission approval responds with the official granted-profile shape and scope; no generic command decision is a substitute.

## Observation and compatibility

Use nested `tokenUsage.last` for latest context usage and `tokenUsage.total` for cumulative counters; `modelContextWindow` can be null. A raw latest-total/window fraction is an estimate, not an exact clone of the TUI baseline-adjusted percentage. Keep absent values unknown.

Store `turn/diff/updated` as the current aggregate diff, replacing the previous value; it is not an append-only patch stream. Store `turn/plan/updated` as structured step/status data. Keep these separate from the existing SSH working-tree diff.

Preserve model catalogue `description`, `inputModalities`, `multiAgentVersion`, `serviceTiers`, `defaultServiceTier`, and existing reasoning/default/upgrade fields where present. Display only server-advertised options and avoid hardcoded current model names.

Optional features have connection-scoped unknown/supported/unavailable state. A method-not-found or explicit experimental-capability rejection disables only that feature. Timeouts, connection failures, and authorization failures are errors, not proof that a feature is unsupported. Capability probes must be reads; never mutate a goal or compact a thread to test support.

## Verification

Use pinned wire-payload fixtures for goals, status, pagination, token usage, request decisions, history rehydration, and late events. macOS CI verifies Swift type checking and tests. Live validation uses the user's existing server without deploying a second process. None of this closes the separate real-device ChatGPT login, account isolation, or SideStore gates.

