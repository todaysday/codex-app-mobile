# Thread-scoped composer

## ADDED Requirements

### Requirement: Drafts belong to a host, workspace, and thread

The application MUST keep separate in-memory drafts for each host/workspace/thread scope, including a separate new-thread scope. Text and selected context tokens MUST be restored together. App navigation and tab switching MUST preserve drafts for the lifetime of AppState.

#### Scenario: Switching between existing threads
- **GIVEN** thread A has unsent text and selected context tokens
- **WHEN** the user switches to B and later returns to A
- **THEN** B shows only B's draft and A restores its original text and tokens.

#### Scenario: Equal thread identifiers on different hosts
- **GIVEN** two hosts or workspaces use the same thread identifier
- **WHEN** either draft changes
- **THEN** the other scope is unchanged.

#### Scenario: New-thread composer and application navigation
- **GIVEN** a workspace has an unsent new-thread draft
- **WHEN** the user navigates away and returns within the same application process
- **THEN** that workspace's new-thread draft is restored without creating a remote thread.

### Requirement: Submission routing is immutable across suspension

The client MUST capture its target host, workspace, thread, prompt, context tokens, model, reasoning, and collaboration mode before awaiting connection or an RPC. A later selection change MUST NOT redirect the request or be reversed by its completion.

#### Scenario: Thread changes during connection
- **GIVEN** a prompt was submitted for A while the client is reconnecting
- **WHEN** the user selects B before connection finishes
- **THEN** the request still targets A and B remains selected.

#### Scenario: Settings change during dispatch
- **GIVEN** a submission captured a model and reasoning level
- **WHEN** the visible composer settings change during an await
- **THEN** the original request uses the captured settings.

#### Scenario: Reconnected thread has an active turn
- **GIVEN** the connection is restored for an existing thread
- **WHEN** metadata and history identify an active turn
- **THEN** the submission steers that exact turn rather than starting another one.

#### Scenario: Active turn cannot be resolved
- **GIVEN** an existing thread is active but its turn ID is unavailable
- **WHEN** the user submits a follow-up
- **THEN** the client reports that the thread must be refreshed and retains the input for recovery without starting a turn.

### Requirement: Failure recovery preserves scope and newer input

A failed request MUST retain its original text and context tokens in the originating scope. Recovery MUST NOT overwrite newer input or populate a different thread's composer. Pending submissions MUST NOT be silently replayed.

#### Scenario: Failure after switching threads
- **GIVEN** a request for A is pending and B is now selected
- **WHEN** A's request fails
- **THEN** B's composer stays unchanged and A's input remains recoverable in A.

#### Scenario: Newer draft exists when an older submission fails
- **GIVEN** the user has typed a newer draft in the original scope
- **WHEN** an earlier request fails
- **THEN** both the newer draft and failed input remain recoverable without silently replacing or sending either.
