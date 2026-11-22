# Codex Mobile

A standalone SwiftUI iPhone app for your **existing Codex App Server**, with a separate **ChatGPT Web** tab. Codex is the default screen. Codex on the VPS, ChatGPT Web in this app, and the official ChatGPT app retain independent accounts and sessions.

This project extends [shuto-S/codex-app-mobile](https://github.com/shuto-S/codex-app-mobile), preserving its Codex interface and SSH fallback. [Akuma1tko/ChatGPT-WebView](https://github.com/Akuma1tko/ChatGPT-WebView) is the minimal web-companion reference. Exact source revisions and reuse decisions are in [UPSTREAM.md](docs/UPSTREAM.md).

**Delivery status:** [macOS CI #6 passed](https://github.com/todaysday/codex-app-mobile/actions/runs/45036419930): **196 XCTest cases**, **8 Python tooling tests**, and the unsigned iPhoneOS Release build. [Download `CodexMobile-unsigned-6`](https://github.com/todaysday/codex-app-mobile/actions/runs/45036419930/artifacts/14759824839) — version **1.0 (6)**, arm64, iOS 18.0+. The downloaded IPA, checksum, and source provenance were independently verified. [Verification record](docs/VERIFICATION.md); [physical-device acceptance remains pending](docs/DEVICE_ACCEPTANCE.md).

## What is included

| Destination | Behavior |
| --- | --- |
| **Codex** | Existing Hosts → Projects → Threads workflow, workspace CWD, create/resume/fork/archive, model/reasoning/collaboration controls, streaming, approvals, user-input requests, slash commands/MCP/skills, SSH terminal, and local notifications. |
| **ChatGPT** | Official `https://chatgpt.com` in a retained WKWebView, a dedicated persistent web profile, loading/error state, back/forward/reload controls, Safari fallback, and confirmed web-data clearing. |
| **Settings** | Access to the existing host configuration, ChatGPT data/diagnostics, app version/build identity, and attribution. |

The ChatGPT website decides which features the signed-in account receives. The user's actual Google, Apple, email, or passkey login and required Pro/web functionality must be verified on the iPhone. A functioning Safari fallback does not prove that embedded login works.

## Controls adapted from official Codex

The protocol baseline is [Codex 0.171.0](https://github.com/openai/codex/releases/tag/rust-v0.171.0). The [source review](docs/OFFICIAL_CODEX_REVIEW.md) records exact source revisions, contracts, compatibility limits, and reuse decisions.

Open a Codex thread and use its header menu:

| Control | Behavior |
| --- | --- |
| **Thread Controls → Goal** | Read or edit the objective and token budget, pause/resume, mark complete, or explicitly clear the goal. Shows the server's status, tokens, and elapsed time. |
| **Thread Controls → Thread Actions** | Rename the thread, request context compaction, or select a real turn and confirm removal of that turn and later conversation history. History revert does **not** undo changes to files. |
| **Subagents** | Browse reported parent/child relationships, roles, status, and child messages. Return to the parent workbench without creating a session or sending a prompt. |
| **Current Turn** | Inspect the structured plan, latest aggregate server diff, and separate latest/cumulative token counters. |
| **Model details** | Show the connected server's advertised description, supported inputs, reasoning choices, and available service tiers. Model names are not hardcoded. |

Thread discovery follows all returned pages and includes official source kinds where supported. Read/resume restores complete history and the known active turn. Follow-ups steer that exact turn; an interrupt remains pending until the server reports completion. Older servers keep their supported behavior and show unavailable optional controls explicitly.

Approval sheets preserve the server's actual choices, including human checkpoints and scoped permission grants. Unsupported permission shapes cannot be granted. Secret answers use masked input, and free-form answers retain their literal text. A stale sheet cannot approve a new request that reuses an earlier request ID.

Composer drafts belong to their host, workspace, and thread. They retain text and context tokens while navigating within the app; submitted requests retain their original target and settings through reconnects. Failed inputs remain recoverable in their source thread. Drafts are held in memory and do not survive process termination. See the [composer specification](openspec/changes/fix-thread-scoped-composer/specs/scoped-composer/spec.md).

## Requirements

- iPhone with **iOS 18.0 or later**. The first requested physical test is iOS 18.7.8.
- A reachable **existing** `codex app-server` through a protected route.
- SideStore for native installation/signing, or Impactor as a fallback. The app itself runs directly on iOS, outside LiveContainer.
- No personal Mac is needed when the hosted GitHub Actions build is available.
- For local iOS development: macOS, Xcode 26.2, and `make`. The newer Xcode SDK compiles upstream availability-guarded APIs while keeping an iOS 18.0 deployment target.

The app bundle ID is `dev.todaysday.codexmobile`; its test bundle is `dev.todaysday.codexmobile.tests`. It does not reuse the official ChatGPT identity.

## Connect to your existing Codex server

1. Confirm the address and transport of the App Server already running on the VPS. Do not start a second instance for this client. Its existing VPS-side authorization and `CODEX_HOME` remain the source of the Codex account and sessions.
2. Open **Codex → Hosts → `+`** or the host entrypoint in Settings.
3. Enter the host metadata and the full protected App Server endpoint, for example `wss://codex.example.test/socket`. The full URL preserves its scheme, path, and explicit port through edits. The example is a placeholder, not a supplied server.
4. Choose the proxy authentication your deployment actually needs: none, bearer token, or Cloudflare Access service-token client ID/secret. Secrets are stored in iOS Keychain and sent only with the App Server handshake.
5. Open a project workspace, select an existing thread, and use the retained Codex controls. The host context menu exposes the SSH terminal fallback.

For a Release IPA, use **WSS with valid TLS through an authenticated/protected route**. A server listening only at `127.0.0.1` on the VPS needs a route reachable from the phone; entering `localhost` on the phone does not reach the VPS. This project does not deploy or alter that route automatically.

Legacy host/port and private `ws://` records remain readable. Release builds have no global arbitrary-load exception, so reachability and iOS transport restrictions must be checked for the actual private address. Do not expose an unprotected WebSocket publicly to work around connection errors.

If you use Tailscale for Codex and LocalDevVPN for SideStore refresh, plan to switch VPN configurations when needed. The app does not assume both are active simultaneously. A protected WSS route can avoid that dependency for normal use.

## Use ChatGPT Web

Open the **ChatGPT** tab and sign into the intended web account using its normal method. It can be different from the Codex account on the VPS. The browser model and current page survive switching tabs; a named persistent WebKit data store retains valid website login data between launches.

**Clear ChatGPT Web Data** requires confirmation and resets only that dedicated website profile, including its associated authentication-site data. It does not clear Codex hosts or Keychain credentials, Safari, or the official ChatGPT app.

The browser uses WebKit's normal user agent and platform permissions. It does not inject login scripts, extract tokens, impersonate the official app, or bypass website protections. If embedded OAuth is rejected, use the explicit **Open in Browser** fallback and record the failure. This action opens a SafariServices browser sheet with a separate session; logging in there is not promised to log in the embedded WebView.

Actual file upload, microphone/voice, camera, downloads, and account-specific web features are covered by the physical checklist when used. iOS may suspend either network connection in the background; this app does not promise an always-running background socket or a remote push service.

## Build an unsigned IPA with GitHub Actions

In [this repository](https://github.com/todaysday/codex-app-mobile):

1. Open **Actions → iOS unsigned IPA**.
2. Use **Run workflow**, or push to `main`. Pull requests to `main` also run the workflow.
3. Wait for the hosted macOS job to finish successfully. It selects Xcode 26.2, inspects the actual shared scheme/settings, runs simulator tests, and builds the iPhoneOS Release app without signing.
4. Download the artifact named `CodexMobile-unsigned-<run number>` and extract the ZIP.

The distribution contains:

- `CodexMobile-unsigned.ipa` — the app to sign/install.
- `SHA256SUMS` — artifact checksum.
- `build-info.json` — source/build provenance.
- `INSTALL.txt` — installation instructions.

Diagnostics are uploaded as `ios-diagnostics-<run number>-<attempt>`. A failed build or test must be resolved before treating an IPA as a candidate. The CI job needs no Apple ID, signing certificate, provisioning profile, Codex secret, or ChatGPT cookie.

### Install through SideStore

1. Save the extracted IPA in Files on the iPhone.
2. Open SideStore → **My Apps → `+`** and select it.
3. Install it as a standalone application. If SideStore is bundled with LiveContainer, use its installer; do not import Codex Mobile into LiveContainer.
4. Launch the separate Codex Mobile icon and perform the [device acceptance checklist](docs/DEVICE_ACCEPTANCE.md).
5. Perform and verify a real SideStore signature refresh, using LocalDevVPN as required by the installed SideStore setup. Confirm the app launches with its saved host and web data afterward.

Impactor is the fallback signing/install path. Keep bundle identity and signing setup consistent when updating; installation, update, and refresh behavior must be checked on the real device.

## Development

```bash
make validate
```

The portable check runs without Xcode and checks repository/build configuration plus build-tool tests. It does **not** compile Swift or prove that an iOS simulator/device build succeeds.

On macOS:

```bash
make setup-ios-runtime
make run-ios
make test-ios
make build-ipa
```

| Command | Purpose |
| --- | --- |
| `make validate` | Portable repository validation and build-tool unit tests. |
| `make setup-ios-runtime` | Explicitly install an iOS Simulator runtime. |
| `make run-ios` | Build and launch the upstream application scheme on a simulator. |
| `make test-ios` | Run the iOS test suite through the existing local helper. |
| `make build-ipa` | Inspect project/settings, test an available simulator, build the unsigned Release app, and package distribution files under `.build/distribution/`. |
| `make clean` | Remove local `.build` outputs. |

The local run/test helpers do not silently download a missing simulator runtime. Follow the reported `make setup-ios-runtime` instruction. Simulator selection for the distribution build prefers an available iOS 18 iPhone runtime and otherwise uses an available newer iPhone runtime; neither substitutes for the required physical iOS 18.7.8 check.

The application uses SwiftUI, Swift Concurrency, WebKit, URLSession, and the upstream SwiftPM dependencies: `swift-nio-ssh`, `swift-nio-transport-services`, and `Textual` with their transitive packages. No extra web-wrapper dependency is required.

## Specifications and verification

- [Verified build, test results, artifact identity, and remaining live gates](docs/VERIFICATION.md)
- [Project context](openspec/project.md)
- [MVP proposal](openspec/changes/add-chatgpt-web-companion/proposal.md), [design](openspec/changes/add-chatgpt-web-companion/design.md), and [tasks](openspec/changes/add-chatgpt-web-companion/tasks.md)
- Capability specifications: [app shell](openspec/changes/add-chatgpt-web-companion/specs/app-shell/spec.md), [isolated ChatGPT Web](openspec/changes/add-chatgpt-web-companion/specs/isolated-chatgpt-web/spec.md), [existing Codex connection](openspec/changes/add-chatgpt-web-companion/specs/secure-existing-codex/spec.md), [unsigned distribution](openspec/changes/add-chatgpt-web-companion/specs/unsigned-ios-distribution/spec.md)
- [Physical device acceptance and unresolved gates](docs/DEVICE_ACCEPTANCE.md)
- [Official Codex source review](docs/OFFICIAL_CODEX_REVIEW.md), [controls proposal](openspec/changes/add-official-codex-controls/proposal.md), and [capability roadmap](docs/ROADMAP.md)
- [Thread-scoped composer proposal and tasks](openspec/changes/fix-thread-scoped-composer/proposal.md)
- [Original user handoff](docs/handoff/Codex_ChatGPT_Mobile_Handoff.md)

On 2026-11-22 the user additionally authorized implementing suitable features from the current official Codex. Those features are a separate specification and implementation slice; real-device acceptance remains independently required for the browser and installation.

## Source layout

```text
CodexAppMobile/
  App/                         # single app entrypoint and tab shell
  Features/
    Orchestration/             # retained Codex client and host configuration
    Terminal/                  # retained SSH terminal
    ChatGPTWeb/                # isolated browser model, views, and navigation
  Resources/Attribution/       # bundled project and donor notices
CodexAppMobileTests/           # upstream and new iOS tests
scripts/                      # simulator, validation, and packaging helpers
openspec/                     # requirements and implementation tasks
docs/                         # provenance, physical acceptance, and roadmap
.github/workflows/            # hosted macOS test/build workflow
```

## Contributing and licensing

Follow [AGENTS.md](AGENTS.md) and [CONTRIBUTING.md](CONTRIBUTING.md). Existing security reporting guidance is in [SECURITY.md](SECURITY.md).

The base application is MIT licensed; its copyright/permission notice remains in [LICENSE](LICENSE). The donor MIT notice is preserved in [ChatGPT-WebView-MIT.txt](docs/licenses/ChatGPT-WebView-MIT.txt). Official Codex's [Apache 2.0 license](docs/licenses/OpenAI-Codex-APACHE-2.0.txt) and [NOTICE](docs/licenses/OpenAI-Codex-NOTICE.txt) accompany the protocol adaptation. [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) lists dependency attributions. Distribution packaging also carries the license and NOTICE files from the actual pinned SwiftPM checkouts inside the app bundle.
