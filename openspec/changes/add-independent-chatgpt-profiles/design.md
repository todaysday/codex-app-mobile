# Design

## Registry and migration

A main-actor `ChatGPTWebProfiles` owner persists a registry containing profile UUIDs, user-facing names, and the selected UUID in one local preferences document. Each UUID is also its stable WebKit data-store identifier. The initial profile retains `70E5ABF8-5C6B-4E75-A7F1-FF38825C26D3`; new profiles receive fresh UUIDs. No fixed maximum or hard-coded second slot is introduced.

Each profile's `ChatGPTWebViewModel` is created only when needed and remains owned by the registry for the process lifetime. That model retains its own lazy WKWebView, website store, history, popup, download, and reset lifecycle. Creating or selecting a profile in settings does not navigate its browser.

Names describe local browser profiles, not account identities inferred from website credentials. Names must be nonempty after trimming, bounded to 60 characters, free of control characters, and distinct ignoring case. The application does not inspect authentication cookies to infer an email address, login status, or subscription.

## Selection and management

The ChatGPT destination provides a profile menu. Settings exposes the complete profile list, an explicit Add Web Account action with a name field, rename actions, and individually confirmed deletion. Adding a profile selects it for its next visit. The selected UUID is restored across launches; missing or invalid selection metadata falls back to the first available profile without erasing any store.

Switching retains each WKWebView and its navigation history. Switching or adding is blocked while the current profile is clearing data, presenting a profile-owned popup or system sheet, handling a JavaScript dialog, or completing/sharing a download. Main application tabs remain available.

## Independent clear and delete

Clear prompts name the affected profile and retain its registry entry. The action captures the profile/model before awaiting WebKit. Its existing quiescing routine stops that profile's documents before clearing only its named store and temporary downloads.

Deleting a profile first clears that profile successfully, then removes its metadata and retained model. Registry mutations and profile switching are serialized while deletion is in flight. If clearing fails, the profile stays registered and an actionable error is shown. Deleting the selected profile chooses an existing remaining profile; deleting an inactive profile keeps the current selection. At least one profile remains available, and its data can still be cleared. Empty WebKit store containers need not be removed by a separate API; all website data is removed before the registry entry is deleted.

No combined clear-all operation is introduced. Other profiles, Codex credentials, Safari, and the official ChatGPT app retain their own data.

## Verification boundaries

Tests create three or more persistent named stores with random identifiers and set distinct session-fixture cookies sharing the same origin, name, and path. They switch through the real profile owner, reconstruct its persisted registry, clear individual profiles, delete active and inactive profiles, and verify surviving sessions and retained browser instances. A mounted SwiftUI tab test verifies which actual WKWebView is displayed while Codex state stays unchanged.

These tests exercise application storage and switching, not ChatGPT's authentication service. The release checklist still requires real sign-in to the intended accounts, website-visible account identity during switching, relaunch, and independent clearing/deletion on the target iPhone. Provider restrictions, revoked sessions, and entitlements remain website behavior.
