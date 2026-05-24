# Changelog

All notable changes to this project will be documented in this file.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — Initial release

### Added

- **Two-Mach-O macOS menu-bar app** (`BastionMenuBar` + `bastion` CLI)
  built on Vigil's scaffold pattern. Non-sandboxed, hardened-runtime
  signed via Developer ID, notarized + stapled, Sparkle 2 auto-update
  with EdDSA signature verification.
- **`~/.ssh/config.d/bastion.conf` integration**: Bastion owns one file
  under `~/.ssh/config.d/`, plus one sentinel-guarded `Include` line at
  the top of `~/.ssh/config`. Every other tool that reads `~/.ssh/config`
  (scp, rsync, mosh, git, VSCode Remote-SSH) automatically sees your
  Bastion-managed hosts.
- **ConnectionEngine**: single `@MainActor` orchestrator for every
  `ssh` / `ssh-add` / `ssh-keygen` invocation. Two-pass `ssh -G`
  validation (isolation + integration) with rollback to `.prev` on
  failure.
- **Host editor** with Basic / Advanced / Raw tabs covering every
  industry-standard SSH option from `ssh_config(5)`. Raw tab validates
  via `ssh -G` on save.
- **ControlMaster** (the headline feature): toggle in onboarding, per-
  host override in the editor. Default `ControlPath ~/.ssh/sockets/%C`
  + `ControlPersist 8h`. FIDO/passphrase always handled in your chosen
  terminal — Bastion never tries to ssh-askpass from the menu bar.
- **In-memory shell-history import** with a checklist UX. Parses zsh /
  bash / fish histories + `~/.ssh/known_hosts`; extracts hosts from
  ssh / scp / sftp / mosh / rsync / git commands. Nothing is persisted
  except your explicit selections.
- **Runtime terminal detection** for 10 emulators: Terminal.app,
  iTerm2, Ghostty, Warp, kitty, WezTerm, Alacritty, Rio, Tabby, Hyper.
  Bastion suggests iTerm2 > Ghostty > … > Terminal.app as the first-
  launch default.
- **Expandable per-host diagnostics card**: status dot, resolved
  address, master pid, attached-session count, master uptime (survives
  app restart), last error.
- **Keychain-backed passphrase storage** (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)
  for keys Bastion generates. Never iCloud-synced. Auto-`ssh-add
  --apple-use-keychain` on app launch — but skipped when 1Password /
  Secretive SSH agents are detected.
- **ed25519 key generation** in-app (raw + ed25519-sk for FIDO).
- **Opt-in notifications** for ControlMaster drops, SSH cert expiry
  (<7 days warning / <48 hours notification), Keychain locks, external
  config edits. Coalesced per-host via `threadIdentifier`.
- **NWPathMonitor** for VPN drop / Wi-Fi reconnect detection; refreshes
  master state on path-up.
- **iCloud Drive / Resilio sync detection** via
  `~/.ssh/.bastion-host-fingerprint`; surfaces a non-blocking warning
  banner when fingerprint mismatch suggests multi-Mac sync.
- **AppleScript escape helper** (`AppleScriptEscape.string`) with fuzz
  tests; every osascript call funnels through it.
- **Atomic write semantics** for `hosts.json` and `bastion.conf` (temp
  → fsync → rename); rotating GFS backups (last 10 + one per day for
  7 days).
- **Symlink-aware** writes to `~/.ssh/config` — preserves the link for
  chezmoi / dotbot / 1Password / GNU Stow setups.
- **Captured interactive-shell PATH** so child processes spawned by
  the menu app see /opt/homebrew/bin etc., not the launchd-default
  minimal PATH.

### Security

- Bundled `bastion` CLI signed with Hardened Runtime + Developer ID.
- `com.apple.security.automation.apple-events = true` entitlement (the
  one meaningful diff from Vigil's empty entitlements) — required for
  AppleScript-driven Terminal.app / iTerm2 launches under Hardened
  Runtime; `NSAppleEventsUsageDescription` in Info.plist explains why.
- No privileged helper. SSH is entirely user-space; no sudoers, no
  root operations, no `pmset`.
