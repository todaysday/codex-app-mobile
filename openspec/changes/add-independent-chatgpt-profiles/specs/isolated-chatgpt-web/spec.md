## MODIFIED Requirements

### Requirement: Dedicated persistent website session

WHEN the user opens ChatGPT, the application SHALL use a selected named persistent website profile from a locally persisted registry. Each profile SHALL retain its own long-lived WKWebView and stable dedicated website data store. The initial profile SHALL reuse the previously shipped store identifier `70E5ABF8-5C6B-4E75-A7F1-FF38825C26D3`; additional profiles SHALL receive distinct stable identifiers. The application SHALL support more than two profiles without a hard-coded pair of slots. No profile SHALL use Codex credentials for website authentication.

#### Scenario: Upgrade preserves the existing profile

GIVEN the previous application version has a valid persistent ChatGPT website session
WHEN the upgraded application creates its initial profile registry
THEN the initial profile uses the previously shipped website store identifier
AND it does not intentionally erase or migrate that profile's website data.

#### Scenario: Three accounts on the same origin

GIVEN the website issues different sessions in three named profiles
WHEN the same cookie name, origin, and path are used by all sessions
THEN each profile retains its own value and website data
AND no profile reads or copies another profile's session.

#### Scenario: Relaunch preserves profiles and valid sessions

GIVEN several profiles have persistent website sessions and a non-initial profile is selected
WHEN the application is restarted
THEN it restores the profile names, stable identifiers, and selected profile
AND it does not intentionally replace any profile's login data.

#### Scenario: Website expires one session

GIVEN the website expires or revokes one account's session
WHEN that profile next requires authentication
THEN the application shows the website's actual login state
AND it does not claim that persistence guarantees a valid login.

### Requirement: Explicit scoped data clearing

WHEN the user requests to clear ChatGPT web data, the application SHALL ask for confirmation naming the affected profile. After confirmation it SHALL stop that profile's browser activity, clear only that profile's dedicated store and temporary downloads, and retain the profile registration with a clean browser state. It SHALL serialize reset and bind the action to the confirmed profile independently of subsequent UI state.

#### Scenario: Cancel clearing a profile

GIVEN the clear-data confirmation names one profile
WHEN the user cancels
THEN no profile's website data is removed
AND all retained browser instances remain available.

#### Scenario: Clear one profile among several signed-in accounts

GIVEN three profiles contain separate sessions and Codex credentials are saved
WHEN the user confirms clearing one named profile
THEN only that profile's website data and temporary downloads are removed
AND the other profiles' sessions and retained browser instances remain unchanged
AND Codex credentials, Safari, and the official ChatGPT app remain unaffected.

#### Scenario: Reset is already in progress

GIVEN the selected profile is clearing website data
WHEN another navigation, profile switch, or clear action is requested
THEN overlapping work against that profile is prevented
AND callbacks from the discarded page cannot replace another profile's state.

### Requirement: Real login remains a release gate

BEFORE multi-account web support is declared fully accepted, the exact release candidate SHALL pass the intended accounts' actual login methods and required web functionality on the target iPhone. Controlled cookie fixtures, login pages, generic WebView tests, and working Safari sessions SHALL NOT count as successful embedded authentication.

#### Scenario: Automated session tests pass

GIVEN CI verifies at least three named cookie stores, switching, reconstruction, independent clearing, and deletion
WHEN real multi-account ChatGPT authentication has not been tested on the target iPhone
THEN the device login gate remains pending
AND the report distinguishes tested profile behavior from unverified account authentication.

#### Scenario: Multi-account device acceptance

GIVEN the intended different accounts can sign in through their required embedded login methods
WHEN the tester switches profiles, relaunches, and clears or deletes one profile
THEN the tester verifies each website-visible account identity and surviving profiles' logins
AND records account-specific required features independently.

## ADDED Requirements

### Requirement: Explicit profile management in settings

Settings SHALL present the saved profile list and an explicit Add Web Account action that accepts a user-facing name. The application SHALL create a fresh isolated persistent profile, select it, and permit additional profiles beyond the second. It SHALL allow renaming without changing the store identifier or session. Profile names SHALL be nonempty, bounded, free of control characters, and distinct ignoring case.

#### Scenario: Add a third profile

GIVEN two profiles already exist
WHEN the user opens settings, chooses Add Web Account, and enters a valid distinct name
THEN a third profile appears with its own stable store identifier
AND it becomes selected without starting website navigation from settings.

#### Scenario: Rename a signed-in profile

GIVEN a profile has saved website data and a retained browser
WHEN the user renames it in settings
THEN the list and selector display the new name
AND its identifier, website data, and browser instance remain unchanged after relaunch.

#### Scenario: Invalid or ambiguous name

GIVEN the add or rename form is open
WHEN the submitted name is empty, over the length limit, contains control characters, or duplicates another name ignoring case
THEN the form explains the problem
AND the existing registry and website data remain unchanged.

### Requirement: Explicit retained profile selection

The application SHALL expose all registered profiles in the ChatGPT destination and its settings, persist the selected profile, and retain created browser models when switching. Labels SHALL describe local profiles without inferring account identity or subscription. Profile selection SHALL NOT navigate an unused profile until its browser destination is opened.

#### Scenario: Switch among three profiles and return

GIVEN three profile browser views have been created
WHEN the user switches among them and returns to the first
THEN the app displays each corresponding retained WKWebView
AND preserves the other profiles' navigation state and Codex selection.

#### Scenario: Select an unused profile from settings

GIVEN an additional profile's browser has never been opened
WHEN the user selects it in settings
THEN the preference is saved
AND no website request begins until ChatGPT is opened.

#### Scenario: A profile has a pending interaction

GIVEN the current profile is presenting a profile-owned popup, browser/share sheet, JavaScript dialog, or unfinished download
WHEN the user attempts to select or add another profile
THEN the application keeps the current selection until the interaction finishes or is dismissed
AND does not present that interaction as belonging to another account.

#### Scenario: Invalid saved selection

GIVEN persisted selection metadata does not identify a registered profile
WHEN the application creates the profile owner
THEN it selects the first registered profile without changing profile identifiers or website data.

### Requirement: Confirmed individual profile deletion

The application SHALL ask for confirmation naming a profile before deleting it. It SHALL clear that profile's website data successfully before removing its registration and retained browser. It SHALL serialize registry mutations during deletion, retain the registration if cleanup fails, and always leave at least one available profile.

#### Scenario: Delete an inactive profile

GIVEN three profiles contain separate sessions and one is selected
WHEN the user confirms deleting a different profile
THEN the deleted profile's website data is cleared and its registry entry is removed
AND the selected profile and remaining sessions stay unchanged.

#### Scenario: Delete the selected profile

GIVEN at least two profiles exist
WHEN the user confirms deleting the selected profile
THEN only its website data is cleared
AND a remaining existing profile becomes selected and is restored on the next launch.

#### Scenario: Cleanup fails

GIVEN a profile's active page cannot be safely stopped for data clearing
WHEN its deletion is attempted
THEN the app retains the profile registration and shows a recoverable error
AND it does not clear or delete any other profile.

#### Scenario: Attempt to delete the last profile

GIVEN only one profile remains
WHEN the settings management actions are shown
THEN deletion is unavailable with an explanation
AND the user can still clear that profile's website data or add another profile.
