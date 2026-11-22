# Physical device acceptance

This checklist is the release gate for the MVP. Device and live-server results remain **pending** until actually performed; the verified build and download are recorded below. A successful local static check, simulator test, or unsigned build does not establish that the user's login method or SideStore works on the requested iPhone.

Run this against one identified IPA. Do not put passwords, service tokens, cookies, authorization callback URLs, private chats, or account recovery information in the record.

## Test record

| Field | Value |
| --- | --- |
| Source commit | `0a1f8b107324faed81acd7ca76858b7bd97c7c8a` |
| GitHub Actions run URL | [Successful run #6](https://github.com/todaysday/codex-app-mobile/actions/runs/45036419930) |
| IPA SHA-256 | `ad1f6f51734c3497f107c5daae46c2675a065add9f66f5adc0ad4eb3973b5673` |
| App version/build and bundle ID | 1.0 (6); `dev.todaysday.codexmobile`; arm64; minimum iOS 18.0 |
| iPhone model | Pending |
| iOS version | First requested target: 18.7.8; actual version pending |
| SideStore version and installation method | Pending |
| Test date and tester | Pending |
| Actual ChatGPT login method | Pending: Google / Apple / email / passkey, as used by this account |
| Existing App Server version and transport type | Pending; record version and route type, not secrets |

## Before testing

1. Obtain a successful unsigned build from the intended `todaysday/codex-app-mobile` repository. Record its source SHA, run URL, and artifact checksum. Do not treat the presence of a workflow file as a build result.
2. Confirm which process and account the existing VPS App Server uses. Use its existing endpoint through a protected route; do not start a second process for this checklist.
3. Identify the user's actual ChatGPT account and login method. The web account may differ from Codex. Keep the official ChatGPT app installed as a separate surface for the isolation checks.
4. Use a WSS endpoint for the Release build. If the deployment depends on Tailscale, document the VPN switch needed for SideStore/LocalDevVPN refresh.

## Required checks

| ID | Action | Expected result | Status / evidence |
| --- | --- | --- | --- |
| D01 | Download the Actions artifact ZIP and extract the unsigned IPA. Compare its checksum with `SHA256SUMS`. | The exact artifact and commit are identified; the IPA is nonempty and contains the built app. | Passed for the downloaded CI artifact; see [verification](VERIFICATION.md). |
| D02 | Use SideStore → My Apps → `+` to sign and install the IPA as a native app. Do not import it into LiveContainer. | Codex Mobile appears as its own application and launches alongside official ChatGPT. | Pending |
| D03 | Launch from a terminated state. | Codex opens by default, with the expected app identity and independent icon. | Pending |
| D04 | Configure the existing WSS endpoint and the authentication mode required by its proxy. | The existing App Server connects; the process/account on the VPS is unchanged. | Pending |
| D05 | Open a project and a pre-existing thread. Send a harmless prompt; use model/reasoning controls; answer an approval or user-input request in an appropriate test task. | Upstream session controls, response streaming, and request handling work. No duplicate turn or server is created. | Pending |
| D06 | Open the SSH fallback for a configured host if used by this deployment. | Terminal and host-key handling remain available; ChatGPT login is not involved. | Pending |
| D07 | Open the ChatGPT tab. | The official HTTPS website loads with working browser controls. | Pending |
| D08 | Sign into the intended ChatGPT account using its actual login method. | Login completes inside the WebView and the intended account/history is available. A working Safari login alone does not pass this check. | Pending |
| D09 | Exercise the web feature or Pro mode required by the account. | The requested feature works in this WebView with that account; the result is recorded without private content. | Pending |
| D10 | Open a ChatGPT conversation, visit Codex and Settings, then return. | The same page/browser state remains; Codex retains its own selected thread and connection. | Pending |
| D11 | Terminate and relaunch the app, then return to ChatGPT. | A still-valid persistent website session is reused. Server-side expiry or revocation is recorded distinctly from client data loss. | Pending |
| D12 | Cancel the Clear ChatGPT Web Data confirmation. | No web data is removed and Codex remains unchanged. | Pending |
| D13 | Confirm Clear ChatGPT Web Data, then revisit the website. | A clean website session is shown; saved Codex hosts, credentials, projects, and server authorization remain intact. | Pending |
| D14 | Check Safari and the official ChatGPT app after D13. | Their independent sessions remain unchanged. | Pending |
| D15 | Sign into ChatGPT Web again, then edit/switch/disconnect the Codex host. | ChatGPT Web remains signed in; the host operation does not manipulate website data. | Pending |
| D16 | Test a website connection failure and, separately, a Codex connection failure. | Each failure is reported by its own module; the other destination remains usable. | Pending |
| D17 | Let the actual SideStore installation complete a supported signature refresh, switching VPN configuration if necessary. Relaunch and inspect saved data. | The refreshed app launches with its host metadata/credentials and valid web data retained. Record the refresh date and result. | Pending |
| D18 | Check diagnostic views and any support output generated during these tests. | No cookies, authorization headers, OAuth codes, passwords, or service-token secrets are present. | Pending |
| D19 | Sign into ChatGPT Web if needed, then use the website's ordinary sign-out action. Inspect Codex, Safari, and the official ChatGPT app. | Codex hosts and authorization remain unchanged. The app does not clear the other profiles; record any independent website-side session invalidation separately. | Pending |

## Additional website checks

Record these when the associated capability is used. Do not infer support from the desktop website or official iOS app.

| ID | Action | Expected result | Status / evidence |
| --- | --- | --- | --- |
| W01 | Select a harmless file using the website's upload control; cancel a second file selection. | The system picker works and cancellation is harmless. | Pending |
| W02 | Request microphone access on a trusted ChatGPT page, first denying and then allowing as supported by iOS. | The user controls access; the app handles denial and records actual voice behavior. | Pending |
| W03 | Test camera or photo selection only if required by the account's workflow. | The required system consent is used and the actual behavior is recorded. | Pending |
| W04 | Open a website-produced download or an external link. | It succeeds through a supported flow or clearly offers the documented fallback; it is not silently discarded. | Pending |
| W05 | If embedded OAuth fails, use the explicit Open in Browser action. | The official website opens safely. This verifies only the fallback and leaves D08 failing/pending. | Pending |
| W06 | Background the app during a Codex turn and resume it. | The app recovers according to iOS limits; no promise of an uninterrupted background socket is inferred. | Pending |

## Official Codex controls and composer acceptance

Run these against the same identified IPA and the existing App Server. Record the actual server version first. Optional methods that the server does not implement should be recorded as unavailable, with ordinary chat still usable. Use a designated test thread for intentional goal and history changes.

| ID | Action | Expected result | Status / evidence |
| --- | --- | --- | --- |
| C01 | Find a saved CLI/desktop-created thread in the correct workspace; inspect history beyond the first list/history page when available. | The thread and retained messages are present without creating a replacement session. | Pending |
| C02 | Reconnect while a turn is running, then send a follow-up and request Stop. | The existing turn is restored, the follow-up steers that turn, and Stop stays pending until the server reports its terminal state. | Pending |
| C03 | Open Thread Controls, add a goal with a budget, pause/resume it, remove the budget, and confirm Clear Goal. | The server confirms each mutation; objective, status, budget, and counters match its state. Opening the panel alone changes no goal. | Pending |
| C04 | Open Subagents on a parent that has real child sessions; inspect a child and return to the parent. | Reported relationships, roles, status, and messages appear. The parent stays selected, and inspection creates no session or turn. | Pending |
| C05 | Inspect a thread that explicitly reports that it rejects direct input. | Messages remain readable; sending and steering are disabled. | Pending |
| C06 | Observe a task that reports a plan, multiple diff updates, and token usage. | Plan statuses update; the diff represents the latest aggregate snapshot; latest and cumulative tokens are distinct. | Pending |
| C07 | Rename a test thread and request compaction while it is idle. | The confirmed name persists; compaction remains busy until a terminal event or a later authoritative idle refresh. | Pending |
| C08 | Select a real turn in a compatible persistent test thread and confirm conversation-history revert. | That turn and later history disappear after reload; repository file changes remain. A busy or incompatible thread cannot be reverted. | Pending |
| C09 | Exercise command, human-checkpoint, permission, and user-input requests that the actual server supports. Resolve a request from another connected client. | Choices, scope, and secret-input behavior match the request. Resolved or replaced requests cannot be submitted from a stale sheet. | Pending |
| C10 | Type distinct drafts in two threads, including context tokens; navigate between them and the ChatGPT tab. | Each draft and its tokens return only in their original host/workspace/thread scope. | Pending |
| C11 | Submit a prompt while connecting, then select another thread or host before the request finishes. | The request retains its original target and settings or reports the connection change. It does not send to the newly selected thread or change the user's newer selection. | Pending |
| C12 | Cause a recoverable submission failure, type newer input, and use Add to draft for the saved failed input. | Both inputs and their context tokens remain recoverable in the original scope; nothing is sent automatically. | Pending |

## Failure record

For a failed gate, record the test ID, commit, device/iOS, short reproducible steps, exact safe error text, expected result, and observed result. Remove private content and any token-bearing URLs from screenshots. Keep failed and unperformed gates distinct.

If the intended OAuth method is blocked inside WKWebView, retain the functioning Codex client and the Safari fallback, record the defect, and leave full MVP acceptance open. Do not substitute a different login method without the user's decision or claim that cookies automatically transfer from Safari.

## Acceptance decision

- [x] A successful macOS build and artifact have been recorded.
- [ ] D01–D19 have evidence and pass, or a documented explicit product decision changes an applicable requirement.
- [ ] The exact intended ChatGPT login method and required web feature have passed on the requested device.
- [ ] The actual standalone SideStore installation and signature refresh have passed.
- [ ] Any supplementary website limitation is clearly documented.

Acceptance status: **pending**.
