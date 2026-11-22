# Fix independent web profiles and incomplete remote inspection

## Why
A single ChatGPT WebKit profile cannot safely preserve two simultaneously signed-in web accounts. Its Clear command removes the only profile. The current child-agent reader renders flattened transcript text, WSS Host setup requires unrelated SSH fields, and workspace file/worktree inspection is incomplete.

## What changes
- Two switchable, stable, independent persistent ChatGPT web profiles (A and B). Keep existing profile data in A without migration or forced logout; B starts empty. Clear affects only the selected profile.
- Structured read-only subagent conversation with distinct user, assistant, plan, reasoning, command/tool, file-change and unknown-event cards.
- WSS-only Host setup with SSH disabled by default unless explicitly configured; optional SSH fallback remains for existing profiles.
- Read-only workspace browser and bounded file preview using verified official App Server filesystem methods; worktree discovery through configured SSH only unless a real App Server worktree method is verified.

## Scope / limitations
A simulator cannot log into two real ChatGPT accounts. Cookie isolation, preservation and selective clear are unit-tested; actual OAuth, entitlements and persistence require two sign-ins on device. Clearing one local profile cannot undo server-side session revocations from an explicit website logout.
The official 0.171.0 App Server provides fs/readDirectory, fs/getMetadata and fs/readFile but does not report sizeBytes in fs/getMetadata. Its fs/readFile returns the whole base64 file. Safe previews must not issue an unbounded read when size is not known; show a compatibility limit and use a bounded SSH fallback only when separately configured. Newer server metadata may report sizeBytes. There is no verified dedicated App Server worktree CRUD RPC; no invented requests or unconfirmed destructive worktree operations.
Existing Codex sessions, accounts, SSH/Keychain, and pending turns remain unchanged.

## Source contracts
Official Codex stable 0.171.0 (commit ccf9be8cc458bd6b8336fe84d68d8893f2691a5e), codex-rs/app-server-protocol/src/protocol/v2/fs.rs. The current GitHub main was inspected separately for optional sizeBytes. Follow on-wire server capabilities, not CLI assumptions.
