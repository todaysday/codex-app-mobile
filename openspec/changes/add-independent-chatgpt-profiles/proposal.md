# Add independently managed ChatGPT web profiles

## Why

A single persistent WebKit profile cannot keep several ChatGPT accounts signed in independently. The existing tests prove isolation from an unrelated store but do not exercise account switching through the app. Clearing that one profile also clears all sessions inside it. Two accounts are an example, not a product limit: users need an explicit way to add and manage further profiles in settings.

## What changes

- Maintain a persistent registry of named web profiles, each with its own stable store identifier and lazily created browser model.
- Add an explicit Add Web Account action in settings, plus naming, renaming, selection, and confirmed removal of individual profiles.
- Support three or more profiles through a menu/list, without a hard-coded pair of slots.
- Preserve the previously shipped store identifier as the initial profile so an upgrade does not intentionally erase an existing login.
- Scope clear-data and delete actions to the named profile; retain the other profiles' sessions and browsers.
- Add automated same-origin session-fixture tests for three or more profiles, switching, registry reconstruction, independent clearing, and deletion. Keep real account authentication on the target iPhone as a separate acceptance gate.

## Impact

The change affects ChatGPT browser ownership, root wiring, settings, and WebKit integration tests. It adds no dependencies or backend, does not change Codex authentication, and does not transfer sessions from Safari or the official ChatGPT app.
