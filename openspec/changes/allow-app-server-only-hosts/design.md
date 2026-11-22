# Design

`RemoteHost.hasSSHConfiguration` is a derived capability: trimmed host and username must be nonempty and the port must be in 1...65535. It is not inferred from the WSS URL. `RemoteHostDraft` records whether the optional SSH fields are enabled; existing initializers infer that choice from supplied fields for compatibility, and editing a saved host restores the capability.

Validation always requires a name and the existing validated App Server endpoint/security policy. SSH fields are required when SSH is the preferred transport or the user enables an SSH fallback. The draft's normalized persisted SSH fields are empty when fallback is disabled. The editor keeps typed fields while switching transport but does not save hidden credentials as active SSH configuration.

The current Keychain write-before-metadata order is retained: failure to validate/read/save App Server credentials leaves both host metadata and existing SSH password unchanged. Once that succeeds, disabling an old SSH fallback removes its stored SSH password. Existing JSON fields and default transport migration stay backward compatible.

Terminal, SSH directory browsing, and existing SSH Git controls use the capability, with a service-level guard as a second line of defense. The separate App Server file/worktree tools use the current connection and do not read SSH credentials. The UI states the missing capability rather than opening a failing connection to an empty host.
