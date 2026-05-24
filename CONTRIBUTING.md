# Contributing

Bastion is a small focused utility. Contributions are welcome but the surface area is intentionally tight.

## Building locally

```sh
make app
open dist/Bastion.app
```

Local builds are ad-hoc signed. Sparkle stays inert because no `SUFeedURL`/`SUPublicEDKey` are injected.

The release build path (`make release VERSION=…`) requires a Developer ID identity, the Sparkle EdDSA private key, and an App Store Connect API key. Forks cannot run the release workflow — the secrets are not shared with pull-request runs.

## Pull requests

- Run `swift build -c release` and `make app` locally before opening the PR.
  Note: `swift test` requires Xcode (not just Command Line Tools) — the
  tests live under `Tests/BastionCoreTests/` and are exercised by CI on
  every PR. On a CLT-only machine the test target will compile but the
  runner won't execute; rely on `swift build` + CI for green-gating.
- Keep changes scoped. Identifier constants live in `Sources/BastionIdentifiers/`; do not duplicate them.
- The SSH config writer (`BastionCore/SSH/ConfigWriter`) and config scanner (`BastionCore/SSH/ConfigScanner`) are golden-file-tested. Any change to their output needs an updated golden file plus a new fixture covering the change.

## Releasing

Maintainers only. See `RELEASING.md`.
