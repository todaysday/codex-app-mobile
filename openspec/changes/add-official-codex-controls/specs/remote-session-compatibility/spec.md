## ADDED Requirements

### Requirement: Complete source-aware session discovery

WHEN sessions are refreshed, the client SHALL page through `thread/list` with explicit supported source kinds and stable filters, deduplicate thread IDs, and preserve a visible continuation or continue until `nextCursor` is null.

#### Scenario: More than one page

GIVEN a server returns 100 sessions and a continuation cursor
WHEN the client displays the session collection
THEN remaining sessions are obtainable through subsequent pages
AND the collection is not silently declared complete at 100.

#### Scenario: Noninteractive sessions

GIVEN stored exec, app-server, and spawned-agent sessions exist
WHEN the client requests all relevant sessions
THEN it sends explicit source kinds including those sources
AND omitted or empty source kinds are not treated as an all-sources query.

#### Scenario: Failed or repeated continuation

GIVEN a later page fails or returns an already consumed cursor
WHEN the client processes the refresh
THEN it terminates the faulty continuation and reports the incomplete result
AND it preserves existing useful session metadata without an infinite loop.

### Requirement: Read and attach existing history using supported contracts

WHEN a stored thread is opened, the client SHALL distinguish reading history from subscribing to a running thread, use server-provided history and cursor fields, and never create a duplicate thread or server to open it.

#### Scenario: Paginated history

GIVEN a persistent thread uses paginated history
WHEN its messages are loaded
THEN `thread/turns/list` loads full message items with valid cursors
AND an empty summary items list is not represented as an empty conversation.

#### Scenario: Older server

GIVEN the server explicitly lacks history pagination
WHEN existing history is requested
THEN a supported legacy full-history read/resume path remains available
AND an authentication or connection failure is not misclassified as missing pagination.

#### Scenario: Attach to a CLI session

GIVEN a compatible existing thread was opened by another client against the same server
WHEN the mobile user selects it
THEN the client reads or resumes that existing thread as appropriate
AND it does not send `turn/start` merely to attach.

### Requirement: Restore and reconcile active turn ownership

WHEN reconnecting or accepting a thread snapshot, the client SHALL restore in-progress turn identity and retain turn-specific state until a matching terminal notification or authoritative snapshot confirms completion.

#### Scenario: Reconnect during work

GIVEN the server reports an in-progress turn after reconnect
WHEN the selected thread is restored
THEN steering and interrupt target that reported turn
AND opening the workbench does not start a competing turn.

#### Scenario: Interrupt accepted

GIVEN an active turn is interrupted and the request returns success
WHEN the terminal event has not arrived
THEN the UI continues to represent active or stopping work
AND it does not infer completion solely from the interrupt acknowledgement.

#### Scenario: Late completion

GIVEN a newer turn is active when an older turn completes
WHEN the old completion notification arrives
THEN the newer active turn and its pending approval remain intact.

### Requirement: Respect direct-input capability and feature availability

WHEN the server reports `canAcceptDirectInput:false`, the client SHALL disable direct turn input for that thread. Optional capability errors SHALL affect only their corresponding feature and SHALL not erase session history or masquerade as successful execution.

#### Scenario: Read-only child

GIVEN a child reports that it cannot accept direct input
WHEN the child transcript is opened
THEN the transcript remains readable
AND start/steer controls cannot bypass the server restriction.

#### Scenario: Unsupported optional method

GIVEN an optional method is rejected as unknown or requires an unaccepted experimental capability
WHEN its control is used
THEN the feature reports unavailable for that connection
AND ordinary supported chat remains usable.

