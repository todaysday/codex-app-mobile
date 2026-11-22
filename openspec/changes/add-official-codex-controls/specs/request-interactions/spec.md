## ADDED Requirements

### Requirement: Preserve request identity and current approval choices

WHEN a server requests approval, the client SHALL retain the JSON-RPC request identity and thread/turn context, show only applicable decisions, and respect the official command `kind` and advertised `availableDecisions`.

#### Scenario: Human-command checkpoint

GIVEN a request has kind `humanCommand`
WHEN decisions are shown
THEN the user can accept, decline, or cancel
AND session-wide approval is not offered for that checkpoint.

#### Scenario: Resolved request

GIVEN another client resolves the request or the server emits `serverRequest/resolved`
WHEN the local UI receives the resolution
THEN the matching prompt is removed or made non-actionable
AND unrelated requests remain available.

### Requirement: Support explicit permission approval

WHEN `item/permissions/requestApproval` is received, the client SHALL present the requested supported access and respond using the official granted-permission profile and grant scope. Unrecognized permission shapes SHALL not be silently granted.

#### Scenario: Grant current request

GIVEN the user approves supported permissions with the chosen scope
WHEN the response is sent
THEN it contains only the access that was presented and approved
AND it is routed to the original request ID.

#### Scenario: Decline or unsupported permission

GIVEN the user declines or the request cannot be represented safely
WHEN the prompt is handled
THEN the client grants no unapproved access
AND it does not substitute a generic command approval payload.

### Requirement: Preserve user-input question semantics

WHEN `item/tool/requestUserInput` is received, the client SHALL preserve question IDs, headers, prompts, options, `isOther`, and `isSecret`, and answer using the official question-ID-to-answer-list shape. Secret answers SHALL use masked controls and SHALL not enter diagnostics.

#### Scenario: Secret answer

GIVEN a question has `isSecret:true`
WHEN the user types an answer
THEN the control masks the value
AND the value is sent only in the explicit answer response.

#### Scenario: Choice and other answer

GIVEN a question offers choices and an explicit other-answer option
WHEN the user submits a choice or free-form answer
THEN it is associated with that question's actual ID
AND no unrelated default choice is silently substituted.

### Requirement: Distinguish blocking and optional input

WHEN a request includes `isBlocking`, the UI SHALL use it rather than deprecated timing metadata to explain whether the agent is waiting. Older requests lacking the field SHALL retain the protocol's blocking default.

#### Scenario: Nonblocking input

GIVEN `isBlocking:false`
WHEN the request is displayed
THEN the UI does not falsely claim the entire thread is paused for that answer
AND a later resolution prevents a stale answer submission.

