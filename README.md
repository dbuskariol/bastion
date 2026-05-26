# Bastion

> A macOS menu-bar app and CLI for managing SSH connections — every saved host editable from one place, per-host keys, one-click ControlMaster keepalive, recent-host import from your shell history, and Connect-in-your-terminal-of-choice.

See [`docs/0.1.0-design.md`](docs/0.1.0-design.md) for the design rationale.

## Install

1. Download `Bastion-X.Y.Z.dmg` from [the latest release](https://github.com/dbuskariol/bastion/releases/latest).
2. Open the DMG and drag `Bastion.app` to the `Applications` shortcut inside it.
3. Open `Bastion.app` from `/Applications`. The menu-bar icon appears at the right of the status bar.

Auto-updates check daily via Sparkle 2 with EdDSA signature verification.

## What Bastion does

- **Manages every SSH host you've ever connected to.** Imports candidates from your shell history (`~/.zsh_history`, `~/.bash_history`, fish history) and `~/.ssh/known_hosts` with a checkbox flow during onboarding.
- **Writes one managed file** at `~/.ssh/config.d/bastion.conf` and injects a single sentinel-guarded `Include` line at the top of `~/.ssh/config`. Every other tool that reads `~/.ssh/config` (scp, rsync, mosh, git, VSCode Remote-SSH) sees your managed hosts automatically.
- **One-click ControlMaster keepalive.** A global "Enable for all" toggle in onboarding, per-host override in the editor. Bastion-owned stable `ControlPath ~/.ssh/sockets/bastion-<id>-%p-%r` and `ControlPersist 8h` by default. Emits a parallel `Match host <hostname>` block so plain `ssh <full-hostname>` and `ssh <alias>` share one master with one auth touch.
- **First-class FIDO/SSO bastion support.** Auto-detects SSO-fronted SSH hosts (WebAuthn / hardware-key challenge), routes the first connect through your terminal for the touch dance, then auto-opens a shell tab once the master comes up. Subsequent connects in the same `ControlPersist` window are instant.
- **Connect opens the terminal of your choice.** Runtime-detected list of installed terminals (iTerm2, Ghostty, Warp, WezTerm, kitty, Alacritty, Rio, Tabby, Hyper, Terminal.app) — your pick gets a one-click Connect from the popover.
- **Expandable per-host diagnostics card**: resolved address, master uptime, attached process count, last-error, opt-in remote `uname/uptime`.
- **Generate ed25519 keys on demand**, store the passphrase in macOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — never iCloud-synced).
- **Opt-in notifications** when a master drops or comes up, when `ControlPersist` expires, when your SSH cert is about to expire, or when an imported host changes in `~/.ssh/config` from outside the app.

## Use

From the CLI (after `make install`):

```sh
bastion --version
bastion --help
# bastion list / show / add / edit / remove
# bastion connect <alias>
# bastion master start|stop|check <alias>
# bastion import --source zsh|bash|fish|known-hosts|ssh-config|all
# bastion terminal list|set <id>
# bastion config doctor
# bastion config sync
# bastion config rollback
# bastion uninstall
```

From the menu bar: click the key icon to open the popover. Each host has a `▸` connect button (opens a shell in your terminal of choice) and a chevron that expands an inline diagnostics card. The footer carries the terminal picker, a refresh button, gear (re-run setup), clipboard (copy diagnostics), an update check, and quit.

## How it works

Bastion is structured as two Mach-Os: the SwiftUI **menu app** (`BastionMenuBar`) and the **CLI** (`bastion`, embedded in `Bastion.app/Contents/Resources/bastion`).

The menu app does not invoke `ssh` directly. It is a controller: every read goes through `ssh -G <alias>` (the canonical "what would `ssh` actually do?" probe), every connect shells out to the user's chosen terminal app via AppleScript, and every status check uses `ssh -O check`. The CLI surface mirrors every operation the menu app offers so anything scriptable from the popover is also scriptable from a shell.

The menu-bar surface itself is AppKit-level — `NSStatusItem` + `NSPopover` + `NSHostingController` — rather than SwiftUI's `MenuBarExtra(.window)`. That choice is empirically load-bearing on macOS 13, where `MenuBarExtra(.window)`'s private NSPanel does not re-negotiate its `intrinsicContentSize` when the popover's body shape changes (the host list grows and shrinks, cards expand and collapse). Migrating off it gives Bastion true dynamic popover sizing on every macOS Bastion supports.

Configuration writes go through a two-pass validation step (`isolation` pass against a tempfile, `integration` pass against the composed user config) with rollback to `bastion.conf.prev` on failure. The Bastion-owned `Include` block in `~/.ssh/config` is sentinel-guarded so `bastion uninstall` removes it cleanly without disturbing the rest of the file.

For the full design rationale see [`docs/0.1.0-design.md`](docs/0.1.0-design.md).

## Trust model

Bastion runs as a non-sandboxed app with the hardened runtime enabled and the `com.apple.security.automation.apple-events` entitlement (required for AppleScript-driven terminal launches like Terminal.app / iTerm2). It does **not** install a privileged helper — SSH is entirely a user-space activity and Bastion has no root operations.

Auto-updates land via Sparkle 2 from a stable URL: `https://github.com/dbuskariol/bastion/releases/latest/download/appcast.xml`. The appcast is EdDSA-signed; the public key is baked into `Info.plist` (`SUPublicEDKey`). Sparkle refuses to install any update whose signature doesn't verify.

## Safety

Bastion reads and writes the user's SSH configuration and orchestrates `ssh`/`ssh-add`/`ssh-keygen` on the user's behalf. A few load-bearing properties:

- **Bastion owns exactly one file in `~/.ssh/`** — `~/.ssh/config.d/bastion.conf`, plus one sentinel-guarded `Include` line at the top of `~/.ssh/config`. Everything else (existing `Host` blocks, `Match exec` rules, wildcards, identity files, certs, known_hosts) is left untouched. Hand-edits to those files do not conflict with anything Bastion writes.
- **The Bastion-owned file is regenerated wholesale on every save**, from a single registry (`~/Library/Application Support/Bastion/hosts.json`). Manual edits to `bastion.conf` are overwritten — the comment header in the file says so explicitly.
- **Raw overrides** (the per-host Raw tab) refuse to contain `Host`, `Match`, `Include`, or `ControlMaster`/`ControlPath`/`ControlPersist` lines. That keeps the per-host stanza shape stable so the writer can always parse/round-trip it.
- **Master sockets** live under `~/.ssh/sockets/bastion-<stable-id>-%p-%r`. The `-%p-%r` tokens are load-bearing: OpenSSH does not validate the `(user, host, port)` tuple against an existing master before mux-attaching, so the socket name is the segmentation primitive. Without `-%r`, `ssh otheruser@host` could attach to a master authenticated as a different user.
- **Private-key passphrases** are stored in the macOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so they never sync to iCloud and never decrypt unless the Mac is unlocked.
- **FIDO/SSO bootstrap** runs in the user's terminal, never in a hidden subprocess. The browser-touch dance happens in plain sight; Bastion polls `ssh -O check` afterward to detect when the master came up.

## Build from source

```sh
make app
open dist/Bastion.app
```

CLI only:

```sh
swift build -c release
.build/release/bastion --version
```

Install the CLI globally:

```sh
sudo make install     # symlinks → /usr/local/bin/bastion
sudo make uninstall
```

Release builds (Developer ID + hardened runtime + Sparkle keys) are maintainer-only. See [`RELEASING.md`](RELEASING.md).

## License

MIT. See [LICENSE](LICENSE).
