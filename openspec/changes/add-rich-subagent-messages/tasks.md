# Implementation tasks

1. [ ] Preserve complete item payloads through decoding and `CodexTurn` conversion without changing existing transcript output.
2. [ ] Add a typed presentation model for messages, commands, file changes, tool calls and agent events with stable identities.
3. [ ] Replace the child transcript with Markdown messages and expandable action/tool/file cards.
4. [ ] Add connection-scoped, cancellation-aware serialized refresh while preserving the last valid snapshot on errors.
5. [ ] Add focused payload, presentation, bounds and refresh-race tests.
6. [ ] Pass repository validation, macOS build and XCTest; record the resulting build evidence.
7. [ ] Exercise a live parent/child session, tool output and file diff on the existing VPS and physical iPhone; record this separately from automated validation.
