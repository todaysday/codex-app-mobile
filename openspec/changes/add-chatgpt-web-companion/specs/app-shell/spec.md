## ADDED Requirements

### Requirement: Codex is the default standalone destination

WHEN the application starts normally, the application SHALL select Codex and present the retained upstream Codex interface inside a shell with Codex, ChatGPT, and Settings destinations. The application SHALL have its own bundle identity and SHALL keep one application entrypoint.

#### Scenario: Ordinary launch

GIVEN an installed application with saved Codex hosts
WHEN the user launches it
THEN Codex is the selected destination
AND saved hosts remain available without an OpenAI web login prompt.

#### Scenario: ChatGPT unavailable at launch

GIVEN ChatGPT is unreachable or its website refuses embedded login
WHEN the user launches Codex Mobile
THEN Codex host and thread workflows remain available
AND the website failure does not gate access to Codex.

### Requirement: Switching tabs preserves working state

WHEN the user switches destinations, the application SHALL retain the same Codex state/client and the same ChatGPT browser model. It SHALL NOT initiate logout, reset navigation, start a new Codex turn, or recreate the website profile as a consequence of tab selection.

#### Scenario: Return to an active Codex conversation

GIVEN a Codex thread is open and receiving a response
WHEN the user visits ChatGPT and then returns to Codex
THEN the same thread and conversation state remain selected
AND no duplicate App Server client or turn is created by the tab transition.

#### Scenario: Return to an open web conversation

GIVEN the ChatGPT browser has an open page and back/forward history
WHEN the user visits Settings or Codex and returns
THEN the existing browser is reused
AND the browser is not automatically navigated back to its home page.

### Requirement: Settings operate on existing module owners

WHEN the user opens Settings, the application SHALL expose an entrypoint to Codex host configuration, ChatGPT browser data controls and diagnostics, app version/build identity, and required attributions. These actions SHALL use the same module owners as the other tabs.

#### Scenario: Update a host through Settings

GIVEN a host is already registered in Codex
WHEN the user follows host management from Settings
THEN the existing host store is used
AND the app does not create an unrelated set of hosts or connections.

#### Scenario: Inspect diagnostics

GIVEN the user opens browser diagnostics or version information
WHEN the information is displayed
THEN it describes the active build and browser state
AND it contains no cookie values, authorization codes, account tokens, or Codex connection secrets.

### Requirement: Upstream Codex operations remain reachable

WHILE the companion feature is installed, the application SHALL retain the existing Hosts, Projects/workspace CWD, thread history/create/resume/fork/archive, model/reasoning/collaboration controls, streaming, approvals, user-input requests, SSH terminal, and local notification behavior.

#### Scenario: Existing thread and approval

GIVEN the user is connected to a compatible existing App Server
WHEN the user opens a known project and resumes a thread
THEN the existing conversation can be viewed and continued
AND model/reasoning selection and server approval requests remain accessible.

#### Scenario: Independent service outage

GIVEN one of the two remote services is unavailable
WHEN the user opens the other destination
THEN the other destination remains usable according to its own connection state
AND the application does not clear either account's stored credentials.
