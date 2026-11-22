## ADDED Requirements

### Requirement: Connect to the existing process

WHEN a user configures a Codex host, the application SHALL connect to the supplied existing App Server endpoint. It SHALL NOT start a duplicate App Server, replace the VPS-side account, or change the existing `CODEX_HOME` as part of the companion integration.

#### Scenario: Existing VPS session

GIVEN a compatible App Server already runs with its own authorization and thread history
WHEN the iPhone connects to that endpoint
THEN the existing server's projects and sessions can be accessed through the retained client
AND the connection flow does not start or reauthorize another server.

#### Scenario: Unreachable local-only endpoint

GIVEN the existing process listens only on the VPS loopback address and no protected route is configured
WHEN connection fails from the iPhone
THEN the application reports the connection failure
AND setup guidance describes a protected route to the existing service instead of claiming `localhost` reaches the VPS.

### Requirement: Preserve full secure endpoints

WHEN a full supported App Server URL is entered, saved, reopened, or edited, the application SHALL preserve its scheme, host, path, and explicit port. Legacy host/port records SHALL remain readable, and malformed endpoints SHALL be rejected before connecting.

#### Scenario: WSS reverse proxy with a path

GIVEN the user supplies `wss://codex.example.test/socket`
WHEN the host is saved and reopened in the editor
THEN the same secure endpoint is retained
AND editing an unrelated field does not convert it to `ws://` or lose `/socket`.

#### Scenario: Existing legacy host

GIVEN a saved record from the upstream host/port model
WHEN the updated application loads it
THEN the record is readable without losing SSH credentials or project references
AND the existing endpoint is not silently replaced with a new VPS address.

#### Scenario: Invalid input

GIVEN an endpoint has an unsupported scheme, missing host, or invalid port
WHEN the user tries to save or connect
THEN the application identifies the invalid input
AND it does not transmit connection credentials to that destination.

### Requirement: Keychain-backed connection authentication

WHEN an endpoint requires bearer authentication or Cloudflare Access service-token authentication, the application SHALL store the corresponding secrets in Keychain and apply them only to that App Server WebSocket handshake. Host metadata, logs, diagnostics, and website requests SHALL NOT contain those values.

#### Scenario: Bearer-authenticated proxy

GIVEN a WSS endpoint is configured with a bearer token
WHEN the WebSocket handshake is created
THEN it carries the configured authorization header to that endpoint
AND the token is not serialized into the host metadata or ChatGPT browser configuration.

#### Scenario: Cloudflare Access service token

GIVEN an endpoint requires a service-token client ID and client secret
WHEN the WebSocket handshake is created
THEN it uses the required service-token headers from Keychain
AND ordinary browser cookies are not used as a substitute.

#### Scenario: No authentication configured

GIVEN a protected endpoint does not require a proxy credential
WHEN the user connects in no-authentication mode
THEN no bearer or Cloudflare service-token header is added.

#### Scenario: Secret storage fails

GIVEN Keychain cannot persist a newly entered connection secret
WHEN the host is saved
THEN the failure is reported
AND the application does not claim that the new secret has been saved successfully or fall back to plaintext metadata.

#### Scenario: Selected authentication has incomplete credentials

GIVEN bearer or Cloudflare service-token authentication is selected but a required secret is missing or cannot be retrieved from Keychain
WHEN the user tries to connect
THEN the application reports the configuration or storage error before sending the handshake
AND it does not silently downgrade the host to no-authentication mode.

### Requirement: Release transport retains system protections

WHEN a Release build connects to an App Server, the application SHALL retain platform TLS validation and SHALL NOT enable a global arbitrary-load exception to accommodate a public insecure endpoint. WSS over an authenticated route is the documented Release path. Compatibility with legacy private WS configuration SHALL NOT be represented as proof that all private addresses work under iOS transport restrictions.

#### Scenario: Invalid TLS certificate

GIVEN an endpoint presents an untrusted or invalid certificate
WHEN the connection is attempted
THEN platform validation may fail the connection
AND the app does not bypass certificate checks.

#### Scenario: VPN choice during signature refresh

GIVEN SideStore refresh uses LocalDevVPN and Codex connectivity uses Tailscale
WHEN setup instructions describe refresh
THEN they explain the need to switch configurations when necessary
AND they do not assume both VPN paths can operate simultaneously.
