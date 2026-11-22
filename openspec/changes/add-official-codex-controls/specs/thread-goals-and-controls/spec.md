## ADDED Requirements

### Requirement: Display persisted goals from the server

WHEN the user opens a thread goal, the client SHALL call `thread/goal/get`, distinguish null from an existing goal, and display the supported objective, status, budget, usage, and elapsed-seconds fields without fabricating missing values.

#### Scenario: Goal exists

GIVEN the server returns a persisted goal
WHEN the goal panel is shown
THEN it presents the returned goal and counters for that thread.

#### Scenario: No goal or unavailable method

GIVEN the response has no goal or the method is explicitly unsupported
WHEN the panel loads
THEN no goal is invented
AND absence of a goal is distinguished from unavailable server support.

### Requirement: Mutate goals only from explicit user controls

WHEN the user sets, edits, pauses, resumes, completes, or clears a goal, the client SHALL use the official goal method with `origin:"user"`, preserve the distinction between an omitted budget and null, and update local state only from a successful response or matching notification.

#### Scenario: Remove a token budget

GIVEN a goal has a token budget
WHEN the user explicitly removes the budget
THEN set sends `tokenBudget:null`
AND omitting the field on an unrelated edit preserves the existing budget.

#### Scenario: Clear or cancel

GIVEN a goal is displayed
WHEN the user confirms clearing it
THEN the client sends `thread/goal/clear` for that thread and observes the result
AND merely opening or cancelling the control sends no mutation.

#### Scenario: Live goal update

GIVEN another client changes the goal
WHEN `thread/goal/updated` or `thread/goal/cleared` arrives
THEN only the matching thread's goal state changes.

### Requirement: Server-backed thread naming and compaction

WHEN the user renames a thread or requests manual compaction, the client SHALL use `thread/name/set` or `thread/compact/start`, respectively. Manual compaction SHALL require an explicit confirmation and an idle compatible thread, and request acceptance SHALL not be reported as finished compaction.

#### Scenario: Rename

GIVEN the user submits a valid thread name
WHEN the server accepts the rename
THEN the matching thread title is refreshed
AND a failed rename does not overwrite the locally displayed confirmed title.

#### Scenario: Compact an idle thread

GIVEN an eligible idle thread and a confirmed compaction request
WHEN `thread/compact/start` returns
THEN the client waits for lifecycle updates or a refreshed authoritative state
AND it does not present the immediate empty response as finished compaction.

### Requirement: Confirmed history revert uses the current API

WHEN the user reverts conversation history, the client SHALL identify a real `beforeTurnId`, require a loaded idle persistent paginated thread and explicit confirmation, and call `thread/revert`. The UI SHALL explain that the selected turn and subsequent history are removed while local file changes remain.

#### Scenario: Confirm revert

GIVEN the user confirms removal from a displayed turn onward
WHEN the server accepts `thread/revert`
THEN retained history is reloaded using the returned official cursors
AND the empty returned `thread.turns` does not erase the retained conversation.

#### Scenario: Ineligible or failed revert

GIVEN a thread is active, ephemeral, legacy-history, or the server rejects revert
WHEN revert is considered or attempted
THEN the client does not claim that history or files were reverted
AND it does not substitute the removed `thread/rollback` method.

