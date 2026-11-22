## ADDED Requirements

### Requirement: Dedicated persistent website session

WHEN the user opens ChatGPT, the application SHALL load `https://chatgpt.com` in a long-lived WKWebView using a dedicated persistent website data store with a stable identifier. It SHALL NOT use an ephemeral store for ordinary browsing or use Codex credentials for website authentication.

#### Scenario: Relaunch preserves a valid login

GIVEN the user has successfully signed in and the website has issued a persistent valid session
WHEN the process is terminated and the application is reopened
THEN the ChatGPT browser reuses the same persistent website profile
AND the app does not intentionally erase or replace its login data.

#### Scenario: Server expires a login

GIVEN the website session has expired or been revoked remotely
WHEN ChatGPT requests authentication again
THEN the application shows the actual website login state
AND it does not claim that a local persistent store guarantees a still-valid login.

### Requirement: Account boundaries are independent

WHILE Codex and ChatGPT are used in the same application, the application SHALL keep Codex connection secrets in Keychain and ChatGPT data in its named website store. It SHALL NOT copy cookies, access or refresh tokens, passwords, or OAuth codes between modules or to the official ChatGPT app.

#### Scenario: Different accounts

GIVEN the existing VPS process uses OpenAI account A
WHEN the user signs into ChatGPT Web as account B
THEN the Codex process keeps account A
AND ChatGPT Web keeps account B independently.

#### Scenario: Change Codex host

GIVEN ChatGPT Web has a valid login
WHEN the user disconnects, edits, or switches a Codex host
THEN the ChatGPT website store is unchanged
AND no website logout is performed by the host action.

#### Scenario: Sign out through the website

GIVEN ChatGPT Web is signed in independently of Codex and the official ChatGPT app
WHEN the user selects the website's ordinary sign-out action
THEN the application does not clear or change Codex credentials or host metadata
AND it does not erase Safari or other applications' local website profiles.

### Requirement: Explicit scoped data clearing

WHEN the user requests to clear ChatGPT web data, the application SHALL ask for confirmation before removing data. After confirmation it SHALL stop active browser activity, clear only the dedicated ChatGPT store, and present a clean browser state. It SHALL serialize the reset so an old in-flight page cannot be treated as the new session.

#### Scenario: Cancel the clear operation

GIVEN the user has opened the clear-data confirmation
WHEN the user cancels
THEN no website data is removed
AND the current browser session remains available.

#### Scenario: Confirm the clear operation

GIVEN the browser is signed in and Codex hosts are saved
WHEN the user confirms clearing ChatGPT web data
THEN the dedicated website profile is cleared and a clean state is presented
AND Codex host metadata and Keychain credentials remain unchanged
AND Safari, other website stores, and the official ChatGPT app are not cleared.

#### Scenario: Repeated actions during reset

GIVEN the clear operation is still in progress
WHEN another reload, navigation, or clear action is requested
THEN the application prevents overlapping reset/navigation work
AND it does not load an authenticated document from the discarded browser state.

### Requirement: Visible navigation and recovery controls

WHEN the browser is in use, the application SHALL provide a loading indicator, reload, appropriate back/forward controls, and an explicit Open in Browser action. Navigation failures SHALL produce actionable UI without exposing sensitive URLs or credential data.

#### Scenario: Connection failure

GIVEN the website cannot be reached
WHEN navigation fails
THEN the user can retry or choose Safari
AND the Codex destination remains functional.

#### Scenario: No history

GIVEN the browser has no earlier or later history entry
WHEN browser controls are displayed
THEN the unavailable history actions are disabled.

#### Scenario: Web content process exits

GIVEN WebKit terminates the page process
WHEN the application observes that termination
THEN the user is offered a recoverable browser state
AND the application does not clear the persistent login profile or Codex state automatically.

### Requirement: Platform-authentic navigation and permissions

WHEN handling website navigation, the application SHALL use the normal WebKit user agent and platform TLS validation. It SHALL NOT inject token-reading or automatic-login JavaScript, bypass site protections, indiscriminately grant media capture, or automatically launch arbitrary custom URL schemes. External navigation and unsupported content SHALL be handled explicitly.

#### Scenario: Embedded authentication rejection

GIVEN an identity provider refuses the embedded browser
WHEN the user encounters the rejection
THEN login help explains the limitation and offers the official site in Safari
AND the app does not spoof a browser or bridge cookies to claim a successful embedded login.

#### Scenario: Microphone request

GIVEN a trusted ChatGPT page requests microphone access
WHEN WebKit and iOS request consent
THEN the user controls that consent
AND denial is handled without granting access silently or affecting Codex.

#### Scenario: External or unsupported navigation

GIVEN a page requests an external destination, custom scheme, or unsupported file operation
WHEN the navigation delegate evaluates it
THEN the application applies its explicit navigation policy
AND no credentials or OAuth callback values are forwarded into Codex or diagnostic logs.

### Requirement: Real login remains a release gate

BEFORE this MVP is declared accepted, the exact release candidate SHALL pass the intended account's actual login method and required web functionality on the target iPhone. A login page, generic WebView test, or working Safari session SHALL NOT count as successful embedded authentication.

#### Scenario: Required login method not yet tested

GIVEN CI passes but the user's Google, Apple, email, or passkey login has not been tested on the target device
WHEN release status is reported
THEN the device login gate remains pending
AND full MVP acceptance is not claimed.

#### Scenario: Account-specific entitlement

GIVEN the account is entitled to a requested ChatGPT web feature
WHEN physical acceptance is performed
THEN the tester records whether that feature is actually available and usable in the embedded browser
AND entitlement support is not inferred from a generic account label or from native-app behavior.
