# Preserve thread-scoped drafts and submission targets

## Why

Official Codex 0.171.0 includes fixes for preserving drafts and queued follow-ups across thread switches. Inspection of this mobile fork found a matching concrete race: `sendPrompt` reads `selectedThreadID` after awaiting connection, so switching threads can redirect an already-submitted prompt. Its error handler can also restore that prompt into another thread's composer. A single view-local draft currently follows the user between threads.

## What Changes

- Keep independent in-memory drafts, including selected context tokens, per host, workspace, and existing or new thread.
- Snapshot the submission target and model/reasoning/collaboration settings before any suspension.
- Recover failed submissions to their original scope without overwriting a newer draft or changing the user's newer selection.
- Reconcile an existing thread after reconnect before choosing between steering an active turn and starting a new one.

## Impact and authorization

This extends the authorized current-official-Codex port with a demonstrated correctness fix. It changes the workbench composer and a small application-owned draft store; it adds no dependencies, remote services, or persistent plaintext prompt storage. Existing SSH behavior remains available, with draft switching using the same scope model.

Source: [official stable release](https://github.com/openai/codex/releases/tag/rust-v0.171.0), pinned to `ccf9be8cc458bd6b8336fe84d68d8893f2691a5e`, including the draft/follow-up fixes. The implementation is adapted to the existing SwiftUI client rather than copying the Rust TUI.

## Acceptance

Tests must exercise scope changes, pending submissions, failure recovery, and preservation of newer drafts. macOS compilation and the combined suite must pass. Real-device acceptance remains tracked separately.
