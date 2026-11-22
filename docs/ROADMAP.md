# Proposed Codex follow-up capabilities

These are specification proposals for later slices. They are not implemented or accepted by the ChatGPT Web MVP. The handoff places them after successful MVP integration, including the intended real-device web login. That ordering remains in force.

This roadmap describes additions to the retained upstream baseline. The inspected client already has workbench Git/diff and approval interfaces; those existing capabilities must remain available in the MVP. The P2 entries below mean expanding that behavior, not removing it until a later release.

## P1.1 — Goal Mode

### Proposed requirement

WHEN a connected App Server supports Goal Mode, the client SHALL allow the user to inspect, set, and clear a thread goal through the server's documented methods. The UI SHALL reflect only fields actually supplied by the compatible server, including `objective`, `status`, `tokenBudget`, `tokensUsed`, and `timeUsedSeconds` where supported.

Candidate methods from the handoff: `thread/goal/get`, `thread/goal/set`, and `thread/goal/clear`. Candidate notifications: `thread/goal/updated` and `thread/goal/cleared`. These names must be checked against the target server's current schema before implementation; this document is not a generated protocol schema.

#### Scenario: Supported goal updates

GIVEN a server with verified Goal Mode support and an existing thread
WHEN the goal changes on the server
THEN the thread's goal view refreshes from the documented notification/payload
AND the client does not invent missing counters or infer an unsupported status.

#### Scenario: Unsupported server

GIVEN the connected server does not expose the required methods
WHEN the user opens the thread
THEN existing chat operations remain usable
AND Goal Mode is unavailable with a clear compatibility explanation.

### Proposed implementation tasks

- [ ] Verify API fields, opt-ins, and notification payloads against the actual App Server version.
- [ ] Add typed protocol handling, a thread goal panel, and explicit set/clear actions.
- [ ] Test notification-driven updates, unsupported methods, reconnect, and missing optional fields.
- [ ] Verify the feature against an existing remote thread without changing the server's account.

## P1.2 — Subagent thread navigation

### Proposed requirement

WHEN the server exposes parent/child thread relationships, the client SHALL present the relationship tree and allow reading a child's messages and status without creating a new child or silently starting a turn. It SHALL use server-reported relationships and the verified filtering/experimental contract.

Candidate filters from the handoff include `parentThreadId` and `ancestorThreadId`. Their availability and experimental opt-in must be verified first. A fallback that merely guesses relationships from transcript text does not satisfy the structured-tree requirement.

#### Scenario: Inspect an active child

GIVEN a parent thread has server-reported child threads
WHEN the user selects a child
THEN its messages and reported status are shown
AND returning to the parent preserves its conversation state.

#### Scenario: Concurrent existing session

GIVEN a thread is already active from CLI or desktop
WHEN the mobile client opens it
THEN it reads and attaches according to the verified server protocol
AND it does not start a conflicting second turn merely by opening the thread.

### Proposed implementation tasks

- [ ] Verify relationship fields, filters, pagination, and experimental API negotiation.
- [ ] Add read-only tree navigation first, then explicit supported controls.
- [ ] Test missing parents, paginated children, unsupported filters, reconnect, and concurrent activity.
- [ ] Verify a real parent/child session created outside the mobile client.

## P2 — Workbench expansion

Proposed slices, in order after the P1 capabilities:

| Slice | Intended behavior | Required verification |
| --- | --- | --- |
| Files and Git diff | Read project files and show server-backed working changes with clear workspace identity. | Verify the actual server API, path handling, large responses, and read-only behavior before adding mutations. |
| Worktrees and history | Inspect and navigate worktree/session context without losing the current thread. | Verify supported operations and concurrency; specify destructive operations separately. |
| Approval and completion visibility | Improve in-app requests and local notification presentation for supported events. | Test foreground/background transitions within iOS limits; do not promise remote push without a separately approved service. |
| Agent action/log presentation | Show useful server-reported activity with appropriate paging and redaction. | Verify schema, volume limits, and absence of secret data in diagnostics. |

Each slice requires its own concrete change proposal and task list after protocol inspection. No placeholder UI should label an unimplemented capability as available.
