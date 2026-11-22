## ADDED Requirements

### Requirement: Two independently persistent ChatGPT Web profiles
The app SHALL expose two named web profiles and keep each profile in its own stable, persistent WKWebsiteDataStore and retained WKWebView. Profile A SHALL reuse the existing deployed store UUID.

#### Scenario: Login data in both profiles
GIVEN each profile has a cookie with the same domain/name but different values
WHEN the user switches A → B → A and the app re-creates its profile controllers
THEN each profile retains only its own value and page state, and neither switch signs the other out.

#### Scenario: Switching without network or a new login
GIVEN two prepared WebViews
WHEN a profile is selected
THEN selection changes the displayed instance without clearing data, sharing authentication, or automatically logging out either profile.

### Requirement: Clear only the chosen profile
The app SHALL require confirmation naming the selected profile, stop its active documents and downloads, and delete data only from that profile's persistent store.

#### Scenario: Clear profile A
GIVEN A and B are signed in separately
WHEN A's data is explicitly cleared
THEN B's cookies and WebView state remain intact, and Codex / Safari / the official ChatGPT app remain separate.

#### Scenario: Cancel clear
GIVEN the clear dialog is open
WHEN the user cancels or switches away
THEN no profile data is removed.

### Requirement: Honest two-login acceptance
The app SHALL not present independent cookies as proof that real OAuth and simultaneous signed-in web access work.

#### Scenario: Two real accounts
GIVEN an iPhone with two valid ChatGPT accounts
WHEN the user logs into A and B using their real providers, relaunches the app and switches
THEN both accounts must remain independently accessible before real dual-login acceptance passes.
