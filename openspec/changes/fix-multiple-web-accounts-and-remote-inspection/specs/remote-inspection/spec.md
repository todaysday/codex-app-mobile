## ADDED Requirements

### Requirement: Browse workspace files with official read-only App Server methods
The client SHALL use documented fs/readDirectory and fs/getMetadata for workspace browsing on a connected App Server, bounded to the selected workspace root and without requiring SSH.

#### Scenario: Normal directory
GIVEN the server supports filesystem reads
WHEN a child directory is opened
THEN its direct child entries appear with file and folder distinctions and no mutation is sent.

#### Scenario: Unsafe traversal or symlink
GIVEN a path would leave the workspace or is a symlink
WHEN selected
THEN the client refuses to follow it.

### Requirement: Never issue an unbounded preview read
The client SHALL only call fs/readFile when metadata supplies a confirmed file size at or below the configured maximum. It SHALL bound decoded content and show unsupported/binary/oversized errors accurately.

#### Scenario: Older App Server
GIVEN fs/getMetadata omits sizeBytes
WHEN a preview is requested
THEN the UI explains that safe read is unavailable rather than requesting a potentially unlimited base64 payload.

#### Scenario: Small text file
GIVEN sizeBytes is known and within the cap
WHEN the user selects a text file
THEN UTF-8 contents are displayed read-only and selectable.

### Requirement: Source-verified worktree discovery
The client MAY expose read-only git worktree listing over already configured SSH, but SHALL NOT invent an App Server worktree CRUD method or destructive operation.

#### Scenario: WSS-only Host
GIVEN no SSH credentials and no verified worktree RPC
WHEN the user opens worktree controls
THEN the UI reports the capability limitation instead of silently using a shell.
