# Workspace file previews and worktree tools

## Why

The workbench currently exposes SSH Git actions but leaves file previews and worktree management on the roadmap. A host configured only with an App Server WebSocket cannot use SSH to fill that gap.

## What changes

- Add a workspace-rooted file browser over the official filesystem methods, with text/code, image and PDF previews.
- Bound previews to 2 MiB and reject oversized or changing files rather than downloading arbitrary content. The public metadata response has no size, so use a bounded Unix `wc` command for size preflight.
- Add Git worktree list, create-new-branch, open-as-workspace and confirmed remove through official `command/exec` argv requests.
- Preserve the server's configured sandbox and permission profile. Never use force removal or shell command interpolation.
- Add protocol, parser, size/path, stale-connection and destructive-action guard tests.

## Scope

This is a first-party SwiftUI implementation on the existing connection. No new backend, package or SSH credential is required. Worktree commands and the size preflight target Unix hosts with Git and `wc`; unavailable utilities or server policy restrictions are displayed as errors. File writes, remote execution from a preview, force removal, pruning, moving and locking worktrees are outside this change.

## Acceptance

Both tools are reachable from a selected workspace; previews and Git operations work against the current host only. Changes are covered by fixtures and macOS XCTest. Live execution on the user's server remains a distinct acceptance check.
