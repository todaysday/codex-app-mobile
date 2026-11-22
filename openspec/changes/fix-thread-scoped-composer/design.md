# Design

Use a typed scope of host UUID, workspace UUID, and optional thread ID. A nil thread ID denotes that workspace's new-thread composer. The long-lived `AppState` owns an in-memory store, so tab changes and navigation do not destroy drafts. Prompt text and selected context tokens are not written to preferences, logs, or ChatGPT's WebKit store.

The view saves its loaded scope before adopting a different combined scope. The loaded scope is separate from the current selection so SwiftUI update ordering cannot accidentally file a draft under the new thread. Saving an empty draft removes it. The application need not preserve drafts across process termination.

Submission captures all routing and request settings synchronously. Awaited network operations use that snapshot. Selection of a newly created thread is allowed only while the user is still in the original composer scope. A completion or failure never selects an unrelated thread. A pending submission owns its recovery draft until success or recovery; recovery preserves any newer draft and remains associated with the original scope.

After reconnect, existing-thread metadata/history is refreshed and the thread is attached before deciding whether to steer. An active status without a known turn ID must fail safely with recoverable input, rather than start another turn. The client continues to enforce explicit read-only thread metadata.

Context-token selection is part of the draft; model/reasoning/collaboration settings are captured per submission. This change does not add an offline execution queue or automatically replay rejected requests.
