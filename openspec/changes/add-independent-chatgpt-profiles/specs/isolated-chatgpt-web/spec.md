## MODIFIED Requirements

### Requirement: Dedicated persistent website session

WHEN the user opens ChatGPT, the application SHALL offer two independently named persistent website profiles. Each profile SHALL retain its own long-lived WKWebView and stable dedicated website data store. Account 1 SHALL reuse the previously shipped store identifier `70E5ABF8-5C6B-4E75-A7F1-FF38825C26D3`. Neither profile SHALL use Codex credentials for website authentication.

#### Scenario: Upgrade preserves the existing profile

GIVEN the previous application version has a valid persistent ChatGPT website session
WHEN the upgraded application first opens Account 1
THEN it uses the previously shipped website store identifier
AND it does not intentionally erase or migrate that account's website data.

#### Scenario: Two accounts on the same origin

GIVEN the website issues account A's session in Account 1 and account B's session in Account 2
WHEN the same cookie name and origin are used by both sessions
THEN each profile retains its own value and website data
AND neither profile reads or copies the other profile's session.

#### Scenario: Relaunch preserves independent valid sessions

GIVEN both profiles have persistent website sessions and Account 2 is selected
WHEN the application is restarted
THEN the application selects Account 2 and reuses both original store identifiers
AND it does not intentionally replace either profile's login data.

#### Scenario: Website expires one session

GIVEN the website expires or revokes one account's session
WHEN that profile next requires authentication
THEN the application shows the website's actual login state
AND it does not claim that persistence guarantees a valid login.

### Requirement: Explicit scoped data clearing

WHEN the user requests to clear ChatGPT web data, the application SHALL ask for confirmation naming the affected profile. After confirmation it SHALL stop that profile's browser activity, clear only that profile's dedicated store and temporary downloads, and present a clean browser state. It SHALL serialize reset and bind the action to the confirmed profile independently of subsequent UI state.

#### Scenario: Cancel clearing Account 1

GIVEN the clear-data confirmation names Account 1
WHEN the user cancels
THEN neither profile's website data is removed
AND both retained browser instances remain available.

#### Scenario: Clear Account 1 while Account 2 is signed in

GIVEN the two profiles contain separate sessions and Codex credentials are saved
WHEN the user confirms clearing Account 1
THEN only Account 1's website data and temporary downloads are removed
AND Account 2's session and retained browser instance remain unchanged
AND Codex credentials, Safari, and the official ChatGPT app remain unaffected.

#### Scenario: Clear Account 2 while Account 1 is signed in

GIVEN both profiles contain separate sessions
WHEN the user confirms clearing Account 2
THEN Account 1's session and retained browser instance remain unchanged
AND a subsequent visit to Account 2 uses a clean browser state.

#### Scenario: Reset is already in progress

GIVEN the selected profile is clearing website data
WHEN another navigation, profile switch, or clear action is requested
THEN overlapping work against that profile is prevented
AND callbacks from the discarded page cannot replace another profile's state.

### Requirement: Real login remains a release gate

BEFORE two-account web support is declared fully accepted, the exact release candidate SHALL pass both intended accounts' actual login methods and required web functionality on the target iPhone. Controlled cookie fixtures, login pages, generic WebView tests, and working Safari sessions SHALL NOT count as successful embedded authentication.

#### Scenario: Automated session tests pass

GIVEN CI verifies two named cookie stores, switching, reconstruction, and independent clearing
WHEN actual two-account ChatGPT authentication has not been tested on the target iPhone
THEN the device login gate remains pending
AND the report distinguishes tested profile behavior from unverified account authentication.

#### Scenario: Two-account device acceptance

GIVEN both intended accounts can sign in through their required embedded login methods
WHEN the tester switches profiles, relaunches, and clears one profile
THEN the tester verifies each website-visible account identity and the surviving profile's login
AND records account-specific required features independently.

## ADDED Requirements

### Requirement: Explicit retained profile selection

The application SHALL expose Account 1 and Account 2 in the ChatGPT destination and its settings, persist the selected profile, and retain both browser models when switching. Labels SHALL describe local profile slots without inferring the signed-in email or subscription. Profile selection SHALL NOT navigate an unused profile until its browser destination is opened.

#### Scenario: Switch away and back

GIVEN both profile browser views have been created
WHEN the user switches from Account 1 to Account 2 and back
THEN the app displays the corresponding retained WKWebView each time
AND preserves the other profile's navigation state and Codex selection.

#### Scenario: Select an unused profile from settings

GIVEN Account 2's browser has never been opened
WHEN the user selects Account 2 in settings
THEN the preference is saved
AND no website request begins until ChatGPT is opened.

#### Scenario: A profile has a pending interaction

GIVEN the current profile is presenting a popup, browser/share sheet, JavaScript dialog, or unfinished download
WHEN the user attempts to select the other profile
THEN the application keeps the current selection until the interaction finishes or is dismissed
AND does not present that profile's interaction as belonging to the other account.

#### Scenario: Invalid saved selection

GIVEN persisted profile-selection metadata is missing or unrecognized
WHEN the application creates the profile owner
THEN it selects Account 1 without changing either profile's store identifier or data.
