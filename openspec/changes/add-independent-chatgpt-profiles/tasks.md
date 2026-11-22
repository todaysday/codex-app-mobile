# Tasks

- [x] Record the profile migration, ownership, reset boundaries, and acceptance scenarios before implementation.
- [x] Incorporate the user's clarification: two is an example; settings explicitly adds and manages further profiles.
- [x] Add a persistent named-profile registry with stable independent store identifiers and lazy retained models.
- [x] Add an explicit Add Web Account form, rename, profile list/menu, and confirmed individual deletion in settings.
- [x] Preserve each retained browser while selecting profiles; remember the selection across launches.
- [x] Scope clear/delete actions to the captured profile, retain other sessions, and handle failed cleanup without unregistering the profile.
- [x] Add automated three-or-more-session, registry persistence, migration, independent-reset, deletion, and mounted-switch tests.
- [x] Run portable validation and the macOS simulator XCTest suite; [CI #17](../../../docs/VERIFICATION.md) passed all 264 XCTest cases, including 13 profile tests and mounted three-browser switching.
- [ ] On the target iPhone, sign into the intended real accounts and verify website-visible identity, switching, relaunch, and clearing/deleting one profile without signing out the others.
