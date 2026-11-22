# Design decisions

## Web profiles
Embed two separate WKWebViews, each retaining its own named WKWebsiteDataStore(forIdentifier:) and delegates. Preserve the original UUID (70E5ABF8-5C6B-4E75-A7F1-FF38825C26D3) for profile A. Allocate a new fixed UUID for B. Both model instances live with the app root and survive tab transitions and profile switches; each model is loaded lazily. Store only selected profile ID in UserDefaults, never cookies, login details or OAuth URLs. A reset must target the exact model captured when confirmation is given. Never use shared removeAllWebsiteData on default store or coordinate clearing across models.

## Child-agent cards
Use the existing typed CodexThreadDetail from threadRead, not generated text. Group by turn and render CodexTurnItem with distinct icon/title/content/status. Command/tool output must be expandable and selectable; file change count and raw unrecognized types remain visible; incomplete data remains unknown rather than guessed. No submit, steer, interrupt, or approval action is attached to an inspection card. Child navigation uses reported parent metadata, retains parent thread selection.

## WSS-only Hosts
A RemoteHostDraft is valid in App Server mode with just display name, a valid full endpoint and credentials. SSH host/user/port remain required only for SSH preference or when SSH fallback is explicitly configured. Endpoint host provides optional neutral host metadata, never fabricated SSH username. Existing JSON host records are compatible; previously configured SSH remains usable. Hide/disable SSH-only entry points if no actual username and reachable SSH address have been configured. Host editing must preserve full endpoint scheme/path/query/port. Legacy host/port WS controls remain available when explicitly used.

## Workspace inspection
Read-only fs/readDirectory is bounded by a local entry cap and only navigates paths resolved inside the selected absolute workspace root. Use fs/getMetadata before preview; follow neither symlink paths nor parent traversal. Call fs/readFile only if the server supplies trustworthy sizeBytes and the size is under a conservative 512 KiB cap; reject binary/unreadable data. Decode UTF-8 text; optional image preview can be supported only within the bound. When size is unknown, explain that this server lacks safe bounded reads. WSS-only Host does not require SSH to browse directories. Optional SSH Git worktree listing requires separate working SSH credentials; never execute git worktree add/remove/prune without a verified reviewed specification and confirmation.
