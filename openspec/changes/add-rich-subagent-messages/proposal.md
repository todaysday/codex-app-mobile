# Add rich subagent messages

## Why

Child threads currently expose a single generated transcript. That loses the distinction between messages, commands, tool calls and file edits, even though the official App Server supplies those items separately. The user asked to close this gap with the current official Codex interface.

## What Changes

- Preserve the structured JSON for each historical item alongside the existing transcript model.
- Render user and agent messages with Markdown and separate cards for commands, file changes, tools, agent actions and other events.
- Show command output and exit status, tool arguments/results/errors, per-file diffs and reported agent destinations in expandable sections.
- Keep read-only child inspection, bounded navigation and parent selection unchanged.
- Refresh visible child snapshots without overlapping requests, token-by-token history reloads or responses from another connection.

## Impact

Affected capability: `subagent-workbench`. Changes are limited to historical payload preservation, the child inspector, isolated presentation/state helpers and focused tests. Existing parent rendering and approval controls retain their behavior. No dependencies, server changes or new protocol methods are introduced.

The user authorized specification and implementation on 2026-11-22. Real-device and live-VPS acceptance remains separate from fixture and simulator validation.
