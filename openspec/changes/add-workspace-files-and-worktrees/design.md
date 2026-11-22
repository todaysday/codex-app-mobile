# Design and source contracts

## Official baseline

Pinned official Codex release: `rust-v0.171.0`, commit `ccf9be8cc458bd6b8336fe84d68d8893f2691a5e`.

| Contract | Primary source |
| --- | --- |
| `fs/readFile {path}` → `{dataBase64}`; `fs/getMetadata {path}` → type/symlink/timestamps; `fs/readDirectory {path}` → child names/type flags | [fs.rs](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/fs.rs) |
| `command/exec` accepts an argv vector, cwd, timeoutMs and outputBytesCap; buffered result is exitCode/stdout/stderr | [command_exec.rs](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/v2/command_exec.rs) |
| Method registration | [common.rs](https://github.com/openai/codex/blob/ccf9be8cc458bd6b8336fe84d68d8893f2691a5e/codex-rs/app-server-protocol/src/protocol/common.rs) |
| Git worktree porcelain and safety semantics | [Git worktree documentation](https://git-scm.com/docs/git-worktree) |

There is no invented `worktree/*` RPC. No filesystem request carries a fictitious range, byte limit or size response field. The client uses the same AppServerClient and its generation/unsupported-method handling.

## Files

Paths are absolute Unix paths within the selected workspace. Child names containing separators, dot components or NUL are rejected. Each traversal validates metadata and refuses symbolic links; this is a client navigation rule, not a replacement for server filesystem authorization. The server remains responsible for authorization and concurrent filesystem races.

Before reading, validate a regular non-symlink file and run `command/exec` with `command:["wc","-c","--",path]`, explicit workspace cwd, 10-second timeout and 4 KiB output cap. Parse the leading byte count. Reject files larger than 2 MiB before `fs/readFile`. Validate encoded length before decoding and the actual decoded length afterward; a changed size is rejected. A 4 MiB WebSocket message cap bounds transport allocation; a file that grows beyond that cap can fail the connection and must show an error rather than pretend success.

Preview UTF-8/UTF-16 text with selectable monospaced content; Markdown may use the existing renderer. Use first-party image decoding with a bounded thumbnail dimension and PDFKit for PDFs. Unsupported binary files show their type and size without attempting text rendering. Previews are read-only and kept in memory; no temporary file is required.

Directory results are explicit, sorted, and do not escape the root. Empty and failed reads remain distinct. A workspace or host switch invalidates in-flight results and mutations by checking both host identity and connection generation.

## Worktrees

All Git commands are argv vectors, never shell strings. Omit `sandboxPolicy`, `permissionProfile`, environment overrides and disable-cap/disable-timeout flags; the server's configured policy remains authoritative. Commands use bounded capture and a timeout shorter than the client request timeout.

List with `git -C <workspace> worktree list --porcelain -z`; parse NUL-separated records so spaces and newlines in paths are not shell- or line-split. Reject incomplete/truncated output. Record main, bare, detached, locked and prunable states. Determine the current worktree from `git -C <workspace> rev-parse --show-toplevel`.

Create validates the branch using `git check-ref-format --branch`, then runs `git -C <workspace> worktree add -b <branch> -- <absolute-destination> HEAD`. The destination and branch remain separate argv entries. Show a create form with the exact destination and new branch; successful creation refreshes the list. A subsequent explicit Open action adds or selects the worktree in the host's local workspace store and starts no turn.

Removal requires confirmation identifying the worktree and re-reads the list immediately before mutation. Refuse main, current, bare, locked, prunable or unfamiliar worktree metadata. Run `git -C <target> status --porcelain=v1 -z --untracked-files=all --ignored=matching` and refuse tracked, untracked or ignored local files, including ignored secrets. Then invoke `git -C <workspace> worktree remove -- <path>` without `--force`. Git's own refusal handles races and submodule restrictions. Do not delete the branch or silently delete local workspace records. After ambiguous connection failure, instruct refresh instead of replaying a mutation.

## Integration

New independent domain, AppServerClient extension and SwiftUI screen files. SessionWorkbench owns sheet presentation and supplies host ID, selected ProjectWorkspace, the shared client, and an explicit open-workspace callback. No parallel connection, automatic SSH attempt or automatic workspace switch after creation.

## Verification

Fixtures cover actual official camelCase shapes, no permission overrides, exact argv boundaries, size/type/path errors, malformed base64, changed sizes, method-not-found, host generation changes, NUL worktree parsing, main/current/locked/dirty guards, and successful create/remove requests. macOS CI checks Swift 6 compilation and XCTest. Physical-device previews and operations on the user's Git repository remain separate live checks.
