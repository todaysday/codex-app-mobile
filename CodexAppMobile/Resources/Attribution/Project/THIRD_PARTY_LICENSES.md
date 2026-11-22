# Third-Party Licenses

This project retains CodexAppMobile and its Swift Package Manager dependencies, and acknowledges the ChatGPT-WebView companion reference. Exact inspected upstream revisions are recorded in [docs/UPSTREAM.md](docs/UPSTREAM.md).

## Application and web companion

| Component | Copyright | License text | Role |
| --- | --- | --- | --- |
| [CodexAppMobile](https://github.com/shuto-S/codex-app-mobile) | Copyright (c) 2026 shuto | [LICENSE](LICENSE), MIT | Base app, Codex interface, orchestration, SSH terminal, tests, and assets. |
| [ChatGPT-WebView](https://github.com/Akuma1tko/ChatGPT-WebView) | Copyright (c) 2025 Akuma1tko | [docs/licenses/ChatGPT-WebView-MIT.txt](docs/licenses/ChatGPT-WebView-MIT.txt), MIT | Minimal WKWebView companion reference; no donor IPA or second app entrypoint is embedded. |

The dependency inventory below is inherited from the inspected upstream revision and its `CodexAppMobile.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. Distribution packaging also verifies resolved checkout revisions and includes their actual `LICENSE` / `NOTICE` files inside the unsigned app.

## Dependencies

| Package | Version | License | Repository |
| --- | --- | --- | --- |
| swift-asn1 | 1.5.1 | Apache-2.0 | https://github.com/apple/swift-asn1.git |
| swift-atomics | 1.3.0 | Apache-2.0 | https://github.com/apple/swift-atomics.git |
| swift-collections | 1.3.0 | Apache-2.0 | https://github.com/apple/swift-collections.git |
| swift-concurrency-extras | 1.3.2 | MIT | https://github.com/pointfreeco/swift-concurrency-extras |
| swift-crypto | 3.15.1 | Apache-2.0 | https://github.com/apple/swift-crypto.git |
| swift-nio | 2.94.1 | Apache-2.0 | https://github.com/apple/swift-nio.git |
| swift-nio-ssh | 0.12.0 | Apache-2.0 | https://github.com/apple/swift-nio-ssh.git |
| swift-nio-transport-services | 1.26.0 | Apache-2.0 | https://github.com/apple/swift-nio-transport-services.git |
| swift-system | 1.6.4 | Apache-2.0 | https://github.com/apple/swift-system.git |
| swiftui-math | 0.1.0 | MIT | https://github.com/gonzalezreal/swiftui-math |
| textual | 0.3.1 | MIT | https://github.com/gonzalezreal/textual.git |

## Notice Files

The following dependencies include a `NOTICE` file. You may need to preserve these notices depending on your distribution model.

- `swift-asn1` (`NOTICE.txt`)
- `swift-crypto` (`NOTICE.txt`)
- `swift-nio` (`NOTICE.txt`)

In particular, `swift-nio`'s `NOTICE.txt` includes additional attributions (for example: Netty / llhttp / uSHET / FreeBSD-derived components).

## Compliance Notes

- `Apache-2.0` dependencies require preserving license text and applicable `NOTICE` content when distributing.
- `MIT` dependencies require preserving copyright and permission notices.
- The final distributor is responsible for validating compliance against the actual shipped artifact (app bundle and any redistributed files).
