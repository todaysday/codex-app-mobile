## ADDED Requirements

### Requirement: Create a Host without SSH credentials
For App Server transport, a display name, valid full WS/WSS endpoint and valid proxy credentials SHALL be sufficient. SSH username and address SHALL be optional and must not be synthesized.

#### Scenario: WSS-only
GIVEN a new Host with name and wss://example.test/socket
WHEN the user saves it without an SSH username or port
THEN it is saved for App Server use and later edits preserve the full URL.

#### Scenario: SSH selected
GIVEN SSH is preferred
WHEN the address, port or username is missing or invalid
THEN Save is disabled and explains the required SSH fields.

### Requirement: Preserve legacy SSH and prevent deceptive fallbacks
Existing Host and Keychain records SHALL keep their SSH configuration. Hosts without SSH SHALL not offer an apparently working terminal, SSH Git action, or SSH-based fallback.

#### Scenario: Existing SSH Host
GIVEN a stored Host with SSH username, address and valid port
WHEN it is edited
THEN the SSH connection remains configured without needing to re-enter fields.

#### Scenario: WSS-only terminal
GIVEN a Host has no SSH username
WHEN the user opens host actions
THEN SSH-only actions are hidden or clearly disabled, while App Server sessions remain usable.
