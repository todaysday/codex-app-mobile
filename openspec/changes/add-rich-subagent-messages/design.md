# Rich child-thread history

## Source baseline

The protocol reference is official Codex `rust-v0.171.0`, commit `ccf9be8cc458bd6b8336fe84d68d8893f2691a5e`:

- [Item variants and their flat wire payloads](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/item.rs): `userMessage`, `agentMessage`, `commandExecution`, `fileChange`, `mcpToolCall`, `dynamicToolCall`, `collabAgentToolCall`, `subAgentActivity`, plan/reasoning and remaining item types.
- [Thread history](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/thread.rs): history remains loaded through the existing metadata-first `thread/read` plus full-item `thread/turns/list` pagination.

## Data flow

`ThreadReadItemPayload` retains its raw `JSONValue` while continuing to decode existing fields for the legacy `CodexTurnItem` model. `CodexTurn` gains `rawItems`, defaulting to an empty list for existing call sites. `convertThread` passes raw items through without changing parent transcript output. No raw payload is logged or persisted by the inspector.

A small presentation model maps actual item `type` values to display kinds. Composite turn/item identity keeps identically named items in different turns distinct. Display ordering follows the server's turn and item order. Unknown fields are retained, and unknown types render a named event card with bounded structured details instead of disappearing.

## Cards

User and assistant text use the existing Textual renderer. Plan and reported reasoning summaries use distinct headers. Command cards show command, working directory, status, exit code/duration when supplied, and expandable output. File-change cards show each path, operation and diff. MCP/dynamic calls show their server/namespace, name, status and expandable arguments/results/errors. Collaboration/activity items expose reported destination threads through the existing safe navigation closure; viewing a card sends no execution request. Review, search, image and compaction events remain identifiable, with structured details where no dedicated preview exists.

Long outputs and JSON are collapsed and bounded in the on-screen preview, with an explicit truncation message. Remote attachment paths are not fetched merely because a history item mentions them, and tool result strings are not interpreted as executable content.

## Refresh and scope

The inspector stores its structured snapshot locally. Reloads are serialized/coalesced, bound to child ID and connection generation, and are cancelled when the view's task ends. Manual refresh remains available. While the scene is active, periodic bounded checks refresh an active child; they do not reload history for every text delta. A successful fresh snapshot replaces prior rows, so completed tools and turns do not accumulate duplicate cards. A failed refresh preserves the last valid snapshot with a visible error. Switching connection generation clears the old snapshot before reading the new connection.

The inspector only uses history reads. It does not attach/resume, start/steer/interrupt, execute commands, answer approvals, change parent selection or synthesize messages from transcript text.

## Verification

Tests cover raw-field preservation through decoding and conversion, distinct card categories, command/tool/file details, reported-only navigation targets, stable identity, unknown item display, bounds, and asynchronous refresh races. SwiftUI compilation and the full existing test suite run on macOS CI. A live parent/child session on the user's existing VPS and physical iPhone remains an unchecked acceptance gate until exercised.
