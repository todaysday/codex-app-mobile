# Tasks

- [x] Record the profile migration, ownership, reset boundaries, and acceptance scenarios before implementation.
- [x] Incorporate the user's clarification: two is an example; settings explicitly adds and manages further profiles.
- [ ] Add a persistent named-profile registry with stable independent store identifiers and lazy retained models.
- [ ] Add an explicit Add Web Account form, rename, profile list/menu, and confirmed individual deletion in settings.
- [ ] Preserve each retained browser while selecting profiles; remember the selection across launches.
- [ ] Scope clear/delete actions to the captured profile, retain other sessions, and handle failed cleanup without unregistering the profile.
- [ ] Add automated three-or-more-session, registry persistence, migration, independent-reset, deletion, and mounted-switch tests.
- [ ] Run portable validation and the macOS simulator XCTest suite; record the exact candidate result.
- [ ] On the target iPhone, sign into the intended real accounts and verify website-visible identity, switching, relaunch, and clearing/deleting one profile without signing out the others.
