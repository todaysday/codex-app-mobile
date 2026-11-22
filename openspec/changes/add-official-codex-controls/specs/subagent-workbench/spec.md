## ADDED Requirements

### Requirement: Build navigation from reported parent relationships

WHEN subagents are shown, the client SHALL use `parentThreadId` and explicit relationship queries, distinguish fork lineage from spawned-child lineage, and preserve meaningful parent/child navigation without synthesizing relationships from message text.

#### Scenario: Load direct children

GIVEN experimental API was accepted and a parent thread is selected
WHEN direct children are requested
THEN the query uses `parentThreadId` and explicit subagent source kinds
AND it does not combine `parentThreadId` with `ancestorThreadId`.

#### Scenario: Fork and attached thread

GIVEN a thread has `forkedFromId` or `attachedToThreadId` without a subagent parent
WHEN relationships are rendered
THEN it is not labeled as a spawned child on that evidence alone.

#### Scenario: Missing parent or cycle

GIVEN a partial page omits a parent or inconsistent metadata contains a cycle
WHEN the tree is built
THEN navigation remains bounded and the available thread can still be inspected
AND the client does not recurse indefinitely or invent missing metadata.

### Requirement: Inspect children without creating or controlling them implicitly

WHEN the user opens a child, the client SHALL show the existing child's messages and reported status, preserve a path back to the parent, and perform no automatic spawn, turn start, goal mutation, or archive.

#### Scenario: Inspect and return

GIVEN an active parent and an existing child
WHEN the user reads the child then returns
THEN the parent remains the same thread with its existing work state
AND no new child or parent turn has been started by navigation.

#### Scenario: Unsupported relationship query

GIVEN a server rejects experimental relationship filtering
WHEN the subagent panel is opened
THEN it shows the compatibility limitation
AND the normal thread history and connection remain available.

### Requirement: Display runtime status accurately

WHEN the server returns thread status or emits `thread/status/changed`, the client SHALL distinguish not-loaded, idle, active, and system-error states and display waiting-on-approval or waiting-on-input flags when present.

#### Scenario: Loaded versus active

GIVEN `thread/loaded/list` contains a thread ID but its status is idle
WHEN its row is displayed
THEN loaded is not represented as actively generating
AND `canAcceptDirectInput:false` remains respected.

#### Scenario: Unknown status

GIVEN the server omits a status or introduces a future value
WHEN metadata is decoded
THEN the thread remains inspectable with an unknown or unavailable status
AND no unsupported active-turn identity is fabricated.

