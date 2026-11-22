## MODIFIED Requirements

### Requirement: App Server hosts do not require SSH

The app SHALL accept a named App Server host with a valid WS/WSS endpoint and the required endpoint credentials without an SSH host, username, password, or user-entered SSH port. Existing WSS-only authentication and endpoint security rules SHALL remain in force.

#### Scenario: Create an authenticated WSS-only host
- **GIVEN** a name, a valid WSS endpoint, and valid credentials for the chosen authentication mode
- **WHEN** SSH fallback is disabled and the SSH fields are empty
- **THEN** validation and persistence succeed and the host can use the App Server transport.

#### Scenario: Invalid endpoint or missing WSS credentials
- **WHEN** the endpoint is invalid or the selected authentication mode lacks required credentials
- **THEN** saving is rejected even though SSH is optional.

### Requirement: SSH is explicit and backward compatible

The app SHALL require a valid SSH host, username, and port when SSH is selected or an optional fallback is enabled. Editing an existing valid SSH configuration SHALL preserve it unless the user disables the fallback.

#### Scenario: SSH selected without fields
- **WHEN** the preferred transport is SSH and host or username is blank or the port is invalid
- **THEN** saving is disabled.

#### Scenario: Incomplete optional fallback
- **WHEN** the preferred transport is App Server and SSH fallback is enabled with incomplete fields
- **THEN** saving is disabled until those fields are completed or fallback is disabled.

#### Scenario: Edit a legacy host
- **GIVEN** a saved host with a valid SSH configuration
- **WHEN** the user opens and saves the editor without changing SSH
- **THEN** its SSH fields, default transport, and existing credential behavior are preserved.

## ADDED Requirements

### Requirement: Missing SSH prevents SSH-only execution

The app SHALL derive SSH availability from validated SSH metadata and SHALL prevent terminal, SSH path browsing, and existing SSH Git operations from starting when that capability is absent. App Server-native actions SHALL remain available independently.

#### Scenario: WSS-only host menu
- **GIVEN** a host without SSH configuration
- **WHEN** the user opens host or workspace actions
- **THEN** SSH-only controls are unavailable with clear context and native sessions, files, and worktrees do not require SSH.

#### Scenario: Accidental service invocation
- **GIVEN** a WSS-only host
- **WHEN** an SSH service is invoked directly
- **THEN** it returns a missing-configuration error before opening a network connection.

### Requirement: Removing fallback is scoped and atomic

Disabling SSH fallback SHALL remove active SSH metadata and the associated stored SSH password only after App Server credentials have been validated and saved successfully. A credential failure SHALL retain the previous host and SSH password.

#### Scenario: Disable a saved fallback
- **WHEN** the user disables fallback and saves valid App Server credentials
- **THEN** the saved record has no SSH capability and the SSH password is removed.

#### Scenario: Credential write fails
- **GIVEN** a saved host with SSH fallback
- **WHEN** disabling fallback fails during the App Server Keychain write
- **THEN** host metadata and the saved SSH password are unchanged.
