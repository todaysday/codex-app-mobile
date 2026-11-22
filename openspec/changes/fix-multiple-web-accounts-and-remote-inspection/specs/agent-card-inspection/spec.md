## ADDED Requirements

### Requirement: Typed child-agent transcript
Opening a reported subagent SHALL render read-only structured turns using the server's typed items rather than a flattened transcript string.

#### Scenario: Mixed child turn
GIVEN a child thread has a user message, reasoning summary, command execution, file-change and assistant reply
WHEN the child is inspected
THEN each item has a distinct card with its type and available status, command/output, or file count.

#### Scenario: Unknown or empty items
GIVEN a newer unsupported tool/event item or a partial history
WHEN it is shown
THEN its reported type is visible, no fabricated execution succeeds, and incomplete state is not silently erased.

### Requirement: Action inspection is non-mutating
Child-agent cards SHALL offer read/copy/expand of reported information but SHALL NOT implicitly start, steer, interrupt, approve, spawn, archive or switch the active parent conversation.

#### Scenario: Inspect while parent is active
GIVEN parent A is running and child B has completed
WHEN B's tool output is expanded and the user returns
THEN A retains its selected thread and in-progress state.
