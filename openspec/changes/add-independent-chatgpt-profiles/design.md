# Design

## Stable ownership and migration

A main-actor `ChatGPTWebProfiles` owner retains two `ChatGPTWebViewModel` instances. Each model continues to own its own lazy WKWebView, website store, history, popup, download, and reset lifecycle. Account 1 retains `70E5ABF8-5C6B-4E75-A7F1-FF38825C26D3`; Account 2 receives a second fixed identifier. Profile selection is non-secret local metadata persisted separately from Codex preferences.

The account labels identify local browser slots. They do not claim to know an email address, account identity, subscription, or successful login. The application does not inspect authentication cookies to infer account status.

## Selection and presentation

The ChatGPT destination presents a two-option profile selector and the chosen model's browser. Changing the selection remounts only the SwiftUI bridge; the owner retains both WKWebViews and their navigation history. Opening an unused profile starts that profile's normal ChatGPT navigation. Selecting a profile in settings does not create or navigate its WKWebView.

Switching is blocked while the current profile is clearing data, presenting an authentication popup or system sheet, handling a JavaScript dialog, or completing/sharing a download. The user can finish or dismiss that interaction before selecting another profile. Switching the application's main tabs remains available.

## Scoped reset

Clear prompts name the affected account. The action captures the profile/model before awaiting WebKit. Its existing quiescing routine stops that profile's documents before clearing only its named store. The other model, website store, browser instance, and navigation state remain intact. No combined clear-both action is introduced.

## Verification boundaries

Tests create persistent named stores with random identifiers and set distinct session-fixture cookies with the same origin, name, and path. They switch through the real profile owner, reconstruct that owner with the same stores, and clear each profile independently. A mounted SwiftUI tab test verifies the actual web-view instance selected on screen and preserved Codex state.

These tests exercise the application's storage and switching behavior, not ChatGPT's authentication service. The release checklist still requires actual successful sign-in to two intended accounts, switching between their website-visible identities, relaunch, and one-profile clearing on the target iPhone. Provider restrictions, revoked sessions, and account entitlements remain website behavior.
