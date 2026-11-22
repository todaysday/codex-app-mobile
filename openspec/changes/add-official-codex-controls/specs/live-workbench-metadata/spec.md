## ADDED Requirements

### Requirement: Decode official latest and cumulative usage separately

WHEN `thread/tokenUsage/updated` arrives, the client SHALL decode `tokenUsage.last`, `tokenUsage.total`, and nullable `modelContextWindow`, preserve reported counters, and distinguish latest context usage from cumulative consumption.

#### Scenario: Official nested payload

GIVEN the event supplies nested last/total usage with a model context window
WHEN counters are displayed
THEN latest context uses the latest reported total rather than cumulative tokens
AND cumulative input, cached input, output, and reasoning counts remain separate.

#### Scenario: Unknown window

GIVEN `modelContextWindow` is null or missing
WHEN usage is shown
THEN the reported token counts remain usable
AND no fixed model window or percentage is invented.

### Requirement: Show server-driven plan and aggregate diff

WHEN `turn/plan/updated` or `turn/diff/updated` arrives, the client SHALL store and display the matching thread/turn's structured plan or latest aggregate diff separately from SSH working-tree inspection.

#### Scenario: Repeated aggregate diff

GIVEN the server sends two aggregate diff snapshots for a turn
WHEN the second arrives
THEN it replaces the prior snapshot
AND the diff is not duplicated by concatenating snapshots.

#### Scenario: Structured plan

GIVEN the server sends an explanation and plan steps with pending/inProgress/completed states
WHEN the plan view updates
THEN it shows those reported steps and states
AND another thread's plan is not overwritten.

### Requirement: Expose current model metadata without hardcoded assumptions

WHEN the server model catalogue is loaded, the client SHALL preserve existing reasoning/default/upgrade information and supported description, input modalities, multi-agent version, and service-tier metadata. Missing optional metadata SHALL not prevent selection of an otherwise valid model.

#### Scenario: Modern catalogue

GIVEN a model advertises modalities, a multi-agent version, and service tiers
WHEN the user inspects model details or supported choices
THEN the UI reflects the supplied values
AND it does not infer capabilities from a model's name.

#### Scenario: Older catalogue

GIVEN the server omits new optional metadata
WHEN the model catalogue is decoded
THEN existing model and reasoning controls remain usable
AND unknown capabilities are not rendered as guaranteed support.

### Requirement: Degrade individual optional features without disrupting the client

WHEN a modern optional method or field is unsupported, the client SHALL preserve working Codex and ChatGPT flows and show a feature-scoped compatibility result. Feature detection SHALL not issue mutating calls.

#### Scenario: Old server and new panel

GIVEN the existing server lacks Goal or advanced metadata support
WHEN the user opens the corresponding panel
THEN its limitation is visible
AND no server upgrade, duplicate daemon, or account login is automatically started.

