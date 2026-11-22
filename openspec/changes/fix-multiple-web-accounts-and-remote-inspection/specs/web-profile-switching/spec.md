## ADDED Requirements

### Requirement: User-managed expandable ChatGPT Web profiles
The app SHALL start with one persistent default ChatGPT Web profile and SHALL allow the user to explicitly add any number of further named profiles in Settings. It SHALL offer selection and rename for every profile, and confirmed deletion except for the last remaining profile. Each profile SHALL have a distinct stable persistent WKWebsiteDataStore identifier and retained WebView, with no shared cookies. The default profile SHALL preserve the deployed original UUID.

#### Scenario: Explicitly create four profiles
GIVEN a fresh installation with one default profile
WHEN the user taps Add Profile in Settings three times and names the new profiles
THEN four independently selectable profiles exist; no second profile appears without an explicit Add action.

#### Scenario: Names and selection persist
GIVEN four profiles with independent names and one selected
WHEN the app terminates and relaunches
THEN the profile list, names, selected ID, and each named WebKit store identity remain stable.

#### Scenario: Switch without logout
GIVEN three prepared WebViews with separate cookies for the same website
WHEN the user switches A → C → B → A
THEN each original WebView and website session is retained and no profile triggers a login/logout, data clear or navigation in any other profile.

### Requirement: Scoped web data clear and profile deletion
The app SHALL capture the intended profile at confirmation, clear only that profile's website data, and never clear another profile, Codex, Safari or the official ChatGPT app. Deleting a profile SHALL also remove its indexed metadata and its named WebKit store only after its WebViews are released. The last remaining profile SHALL be undeletable but clearable.

#### Scenario: Clear selected profile C
GIVEN profiles A, B and C have separate saved session cookies
WHEN the user confirms clearing C
THEN only C's cookies are removed and A and B remain unaffected.

#### Scenario: Target remains stable during confirmation
GIVEN the user opens confirmation to delete profile B
WHEN the displayed profile changes to C before confirmation resolves
THEN only the captured B can be deleted; C's data cannot be cleared as a side effect.

#### Scenario: Failed storage removal
GIVEN WebKit cannot release a profile's data store
WHEN deletion fails
THEN the app shows an error and retains the profile metadata rather than claiming it was removed.

#### Scenario: Cancel or last profile
GIVEN the user cancels deletion or attempts to delete the last profile
WHEN no confirmed eligible deletion occurs
THEN the last profile and all associated data remain unchanged.

### Requirement: Honest multi-account acceptance
The app SHALL not present cookie fixtures as proof of real ChatGPT OAuth. Actual independent sign-in and paid web features on iPhone SHALL be checked against the required number of accounts.

#### Scenario: Three real web accounts
GIVEN an iPhone with three separate ChatGPT accounts
WHEN the user signs into each profile via their real login method, relaunches and switches profiles
THEN all three accounts must remain independently usable before multi-account acceptance passes.
