# Add independent ChatGPT web profiles

## Why

A single persistent WebKit profile cannot keep two ChatGPT accounts signed in independently. The existing tests prove isolation from an unrelated store but do not exercise account switching through the app. Clearing that one profile also clears all sessions inside it.

## What changes

- Keep two named, persistent WebKit profiles and retain one browser model per profile.
- Let the user select Account 1 or Account 2 from ChatGPT and its settings; remember the selection across launches.
- Preserve the existing store identifier as Account 1 so upgrading does not intentionally erase an existing login.
- Scope confirmation, browser reset, downloads, cookies, and website data to the named selected profile.
- Add automated same-origin session-fixture tests for independent accounts, switching, reconstruction, and clearing either profile. Keep actual two-account authentication on the target iPhone as a separate acceptance gate.

## Impact

The change affects ChatGPT browser ownership, root wiring, settings, and WebKit integration tests. It does not add dependencies, change Codex authentication, or transfer sessions from Safari or the official ChatGPT app.
