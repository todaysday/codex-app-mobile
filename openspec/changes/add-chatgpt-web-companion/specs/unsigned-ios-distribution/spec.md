## ADDED Requirements

### Requirement: Reproducible hosted macOS build

WHEN changes are pushed to the main branch or the build workflow is dispatched manually, GitHub Actions SHALL use a hosted macOS runner and a declared Xcode version to inspect the actual project/scheme, run applicable simulator tests, and build the device application. The workflow SHALL NOT assume an unverified product path or scheme.

#### Scenario: Inspect before building

GIVEN the checked-in Xcode project and shared scheme
WHEN CI prepares the build
THEN it records `xcodebuild -list`, toolchain information, and relevant build settings
AND uses the configured application's actual target and product details.

#### Scenario: Build or tests fail

GIVEN source compilation, dependency resolution, or a required test fails
WHEN the workflow finishes
THEN the job is failed
AND no failed build is described as an accepted IPA release.

### Requirement: Unsigned installable artifact layout

WHEN the iPhoneOS Release build succeeds, the packaging process SHALL produce an unsigned `.ipa` containing the actual built `.app` directly under `Payload/`. It SHALL validate the application identity and executable, preserve bundle resources, and expose the result as a downloadable Actions artifact.

#### Scenario: Successful package

GIVEN a successful device application build
WHEN packaging runs
THEN the IPA contains the application executable, Info.plist, assets, and required attribution resources under `Payload/<product>.app`
AND artifact metadata identifies the source commit and build toolchain.

#### Scenario: Missing or wrong product

GIVEN the expected application product is absent, ambiguous, or lacks its executable
WHEN packaging runs
THEN it fails with an actionable error
AND it does not upload an empty or unrelated IPA as a successful deliverable.

### Requirement: No signing credentials in CI

WHEN the device application is built, CI SHALL disable code signing and SHALL NOT require the user's Apple ID, certificate, private key, provisioning profile, website cookies, or Codex host secrets. Installation signing SHALL remain the user's SideStore or Impactor step.

#### Scenario: Fresh public fork

GIVEN the repository contains no Apple signing secrets
WHEN the unsigned build is run
THEN it can compile and package without uploading an Apple identity
AND the output is labeled unsigned.

### Requirement: Standalone identity and attribution

WHEN the application is distributed, it SHALL use its own bundle identity, preserve both upstream MIT notices, and include required dependency license and NOTICE content. It SHALL NOT embed the official ChatGPT executable or reuse its bundle identifier.

#### Scenario: SideStore installation

GIVEN the user signs the generated IPA through SideStore
WHEN the application installs
THEN the intended outcome is a separate iOS application alongside the official ChatGPT app
AND physical verification records whether installation actually succeeded.

#### Scenario: Distributable notices

GIVEN the final IPA is prepared
WHEN artifact verification inspects its resources
THEN the CodexAppMobile and ChatGPT-WebView MIT notices are included
AND resolved dependency licenses and applicable NOTICE files are retained.

### Requirement: Honest release acceptance

BEFORE a release is called complete, the exact artifact SHALL have recorded results for physical installation, the intended ChatGPT login, account isolation, existing-server operation, and a real SideStore signature refresh. Unperformed checks SHALL remain pending.

#### Scenario: CI-only verification

GIVEN compilation and automated tests pass but physical checks have not run
WHEN a build is announced
THEN it is described as a build or MVP candidate
AND unresolved physical acceptance is listed explicitly.

#### Scenario: Signature refresh

GIVEN the application is already installed and has local host/browser data
WHEN the user performs the supported SideStore refresh
THEN the tester verifies that the app launches and its saved data remains available
AND records a pass only after observing the actual refreshed installation.
