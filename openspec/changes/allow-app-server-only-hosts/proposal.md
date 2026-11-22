# Allow App Server-only hosts

## Why

The host editor currently requires an SSH address, username, and port even when the selected connection is a complete WSS App Server endpoint. This makes an independent App Server connection impossible without unrelated placeholder credentials. Existing SSH terminal and Git actions also assume every host has SSH configuration.

## What changes

- Make SSH configuration optional for App Server hosts and expose an explicit SSH fallback switch in the editor.
- Preserve existing SSH hosts and saved fallback settings when editing.
- Save a WSS-only record with no SSH address or username, using the existing non-secret metadata format and Keychain authentication handling.
- Hide or disable SSH-only entry points when SSH is absent and reject accidental SSH execution before attempting a network connection.
- Keep native App Server sessions, new file previews, and worktree tools available without SSH.

## Authorization and scope

The user requested specs followed by implementation and specifically identified the WSS-only validation problem on 2026-11-22. This is an authorized corrective change. Existing SSH/Git features and credential-failure atomicity remain supported. No dependency, VPS process, or authentication configuration is added.

## Validation

Focused tests cover WSS-only creation/editing, incomplete optional SSH configuration, SSH-required validation, persisted metadata, retained existing fallbacks, and capability gating. The full existing XCTest suite and unsigned iOS build remain required. A live connection to the user's VPS is a separate device acceptance gate.
