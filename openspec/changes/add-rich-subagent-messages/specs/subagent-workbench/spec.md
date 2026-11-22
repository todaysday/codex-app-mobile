## ADDED Requirements

### Requirement: Preserve structured child history

WHEN complete historical items are read, the client SHALL retain each item's structured payload and server ordering for child presentation while preserving existing transcript compatibility.

#### Scenario: Tool details survive conversion

GIVEN a full historical MCP item contains arguments, result and error metadata
WHEN a thread is decoded and converted
THEN those fields remain available to the child inspector
AND the existing transcript behavior remains unchanged.

#### Scenario: Complete pagination

GIVEN a child thread uses paginated history
WHEN the inspector loads messages
THEN it uses the existing full-item history loading path
AND items from all returned pages appear in chronological order.

### Requirement: Render distinct message and action cards

WHEN a child snapshot is displayed, the client SHALL render separately identifiable messages and action cards based on official item types rather than parsing a flattened transcript.

#### Scenario: Markdown messages

GIVEN separate user and agent messages include paragraphs, lists and code fences
WHEN the child is opened
THEN each message has its own role-labelled card and Markdown presentation.

#### Scenario: Command execution

GIVEN a command item includes working directory, status, output, exit code and duration
WHEN its card is inspected
THEN the command and reported status are visible
AND the remaining fields and expandable output are available.

#### Scenario: Per-file changes

GIVEN a file-change item contains multiple paths, change kinds and diffs
WHEN its card is inspected
THEN each file can be expanded independently
AND no local file mutation is performed by inspecting the diff.

#### Scenario: Tool call result or failure

GIVEN MCP or dynamic tool items report arguments and results or an error
WHEN the card is inspected
THEN the tool identity, reported status and separate argument/result/error sections are available
AND reading a tool card never invokes the tool.

### Requirement: Preserve reported agent navigation

WHEN collaboration or agent-activity items contain target thread IDs, the client SHALL expose navigation only to those reported destinations through the existing bounded child navigation.

#### Scenario: Collaboration receivers

GIVEN a collaboration item names receiver thread IDs
WHEN the user opens a receiver
THEN the existing inspector navigates to that reported ID
AND parent selection and execution state remain unchanged.

#### Scenario: Prompt is not a relationship

GIVEN a tool prompt mentions a thread ID but supplies no destination field
WHEN the card is rendered
THEN no navigation relationship is inferred from prompt text.

### Requirement: Keep unknown and large items readable

WHEN an unknown item type or long output is received, the client SHALL preserve its place in history, identify the event and bound the on-screen preview with explicit truncation when necessary.

#### Scenario: Future item type

GIVEN an item has a future protocol type and additional fields
WHEN its snapshot is displayed
THEN a labelled event card remains visible with expandable structured details
AND the entire child history does not fail to render.

#### Scenario: Large output

GIVEN a command or tool result exceeds the display limit
WHEN its details are expanded
THEN the preview remains bounded
AND a truncation message distinguishes the preview from complete server output.

### Requirement: Maintain stable and scoped snapshots

WHEN child history is refreshed, the client SHALL serialize reloads, use stable turn/item identities, and apply responses only to the matching child and connection generation.

#### Scenario: Completed item replaces previous snapshot

GIVEN an in-progress command later completes with the same item ID
WHEN the next snapshot arrives
THEN its existing card updates with final status and output
AND no duplicate card is appended.

#### Scenario: Same item ID in different turns

GIVEN two turns contain items with the same ID
WHEN the history is displayed
THEN the rows still have distinct identities.

#### Scenario: Connection changes during read

GIVEN a history read is in flight
WHEN the connection generation or child scope changes before it completes
THEN its response is discarded
AND the previous connection's snapshot is not displayed as current history.

#### Scenario: Refresh fails

GIVEN the inspector already has a valid snapshot
WHEN a same-connection refresh fails
THEN that snapshot remains readable with a visible error
AND a later refresh can recover.

### Requirement: Refresh without controlling child execution

WHILE a child inspector is visible and the scene is active, the client SHALL support manual refresh and bounded periodic refresh for active children without creating or controlling a turn.

#### Scenario: Active child update

GIVEN a visible child remains active
WHEN the refresh interval elapses
THEN its complete snapshot can update without a full-history request for every token
AND no overlapping refresh request is started.

#### Scenario: Inspector exits or app backgrounds

GIVEN automatic refresh is waiting or reading
WHEN the view exits or the scene becomes inactive
THEN the refresh task is cancelled or suspended
AND no new automatic history request is started.

#### Scenario: Read-only inspection

GIVEN a child contains commands, file changes or approval-related output
WHEN the user opens or expands cards
THEN only history reads and local navigation occur
AND no resume, spawn, turn start, approval response or command execution is sent.
