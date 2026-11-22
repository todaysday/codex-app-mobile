# Workspace tools

## ADDED Requirements

### Requirement: Workspace-rooted file navigation

The app SHALL list the selected workspace using official filesystem methods on the current App Server connection, reject unsafe child names and refuse navigation through symbolic links.

#### Scenario: WSS-only host

- **WHEN** the connected host has no SSH configuration and the user opens Files
- **THEN** the app lists `fs/readDirectory` entries without opening SSH.

#### Scenario: Path traversal or symlink

- **WHEN** a returned child contains a slash, dot component or NUL, or metadata identifies a symbolic link
- **THEN** the app refuses that traversal and does not read its file contents.

#### Scenario: Empty directory or read failure

- **WHEN** a directory contains no entries or its RPC fails
- **THEN** the UI distinguishes an empty directory from an error and permits retry.

### Requirement: Bounded read-only previews

The app SHALL preview supported text, code, image and PDF files read-only, checking file metadata and a bounded Unix byte-count command before the full official file read, and enforcing a 2 MiB decoded-content limit.

#### Scenario: Supported small file

- **WHEN** a regular non-symlink file passes the byte-count preflight and returns valid base64 of the same size
- **THEN** the app renders its supported content without writing or executing it.

#### Scenario: Oversized file

- **WHEN** the preflight reports more than 2 MiB
- **THEN** the app explains the limit without sending `fs/readFile`.

#### Scenario: Invalid, changed or unsupported content

- **WHEN** base64 is malformed, the file size changes, or content is an unsupported binary type
- **THEN** the app reports that condition without misrepresenting it as text or a complete preview.

#### Scenario: Missing Unix utility or filesystem capability

- **WHEN** `wc` is unavailable, server policy denies the command, or an official method is unsupported
- **THEN** the app reports the precise failure without adding permission overrides or falling back to an unbounded read.

### Requirement: Official bounded command execution

The app SHALL invoke Git and byte-count commands as argv arrays through `command/exec`, with explicit cwd, output and time limits, and the server's configured permissions.

#### Scenario: Special characters in a path

- **WHEN** a valid path includes spaces or shell metacharacters
- **THEN** the complete path is one argv element and no shell interpolation occurs.

#### Scenario: Truncated command output

- **WHEN** captured output reaches its configured cap or a worktree record is incomplete
- **THEN** the app reports an incomplete response instead of treating a partial list as complete.

### Requirement: Worktree list and creation

The app SHALL display NUL-delimited Git worktree metadata and support explicitly creating a new branch/worktree at an absolute destination.

#### Scenario: Worktree list

- **WHEN** the user opens Worktrees
- **THEN** the app identifies main/current, branch or detached HEAD, locked, bare and prunable records.

#### Scenario: Create a worktree

- **WHEN** the user submits a valid destination and new branch
- **THEN** the app validates the branch, runs `git worktree add -b` without force, and refreshes after success.

#### Scenario: Create failure

- **WHEN** Git rejects the destination, branch or permission
- **THEN** the app preserves the form and reports stderr without claiming the worktree exists.

### Requirement: Explicit workspace opening

The app SHALL add or select a listed usable worktree in the same host's workspace store only when the user chooses Open, without starting a thread or turn.

#### Scenario: Open an existing workspace

- **WHEN** a listed worktree already has a workspace record
- **THEN** Open selects that record instead of duplicating it.

### Requirement: Guarded worktree removal

The app SHALL require explicit confirmation for removal and revalidate the worktree list and clean status immediately before calling non-force `git worktree remove`.

#### Scenario: Protected worktree

- **WHEN** the selected record is main, current, bare, locked or prunable
- **THEN** removal is refused before a remove command is issued.

#### Scenario: Dirty worktree

- **WHEN** tracked or untracked changes are present at the removal preflight
- **THEN** removal is refused and those changes remain on the host.

#### Scenario: Clean linked worktree

- **WHEN** the user confirms a clean unprotected linked worktree
- **THEN** the app runs remove without force and preserves its Git branch and local workspace records.

### Requirement: Host and connection ownership

The app SHALL bind workspace tool requests to the presented host and connection generation and reject stale responses or follow-up mutations after a host/reconnection change.

#### Scenario: Host changes during preflight

- **WHEN** the connection changes between list/status/size preflight and the next request
- **THEN** the app rejects the operation before sending that follow-up to the new connection.

#### Scenario: Connection drops during a mutation

- **WHEN** create or remove has an uncertain result after connection loss
- **THEN** the app reports the failure and requests a list refresh without automatically replaying the mutation.
