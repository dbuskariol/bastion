# Bastion

> A macOS menu-bar app and CLI for managing SSH connections — every saved host editable from one place, per-host keys, one-click ControlMaster keepalive, recent-host import from your shell history, and Connect-in-your-terminal-of-choice.

## Status

Pre-release. Built with the same scaffolding pattern as [Vigil](https://github.com/dbuskariol/vigil). The 12-commit rollout (designed via dual-model-consensus + rubber-duck) is in progress; see `docs/0.1.0-design.md` for the design rationale.

## Install

Once v0.1.0 ships:

1. Download `Bastion-X.Y.Z.dmg` from [the latest release](https://github.com/dbuskariol/bastion/releases/latest).
2. Open the DMG and drag `Bastion.app` to the `Applications` shortcut inside it.
3. Open `Bastion.app` from `/Applications`. The menu-bar icon appears at the right of the status bar.

Auto-updates check daily via Sparkle 2 with EdDSA signature verification.

## What Bastion does

- **Manages every SSH host you've ever connected to.** Imports candidates from your shell history (`~/.zsh_history`, `~/.bash_history`, fish history) and `~/.ssh/known_hosts` with a checkbox flow during onboarding.
- **Writes one managed file** at `~/.ssh/config.d/bastion.conf` and injects a single sentinel-guarded `Include` line at the top of `~/.ssh/config`. Every other tool that reads `~/.ssh/config` (scp, rsync, mosh, git, VSCode Remote-SSH) sees your managed hosts automatically.
- **One-click ControlMaster keepalive.** A global "Enable for all" toggle in onboarding, per-host override in the editor. `ControlPath ~/.ssh/sockets/%C` and `ControlPersist 8h` by default.
- **Connect opens the terminal of your choice.** Runtime-detected list of installed terminals (iTerm2, Ghostty, Warp, WezTerm, kitty, Alacritty, Rio, Tabby, Hyper, Terminal.app) — your pick gets a one-click Connect from the popover.
- **Expandable per-host diagnostics card** (like Vigil's): resolved address, master uptime, attached process count, last-error, opt-in remote `uname/uptime`.
- **Generate ed25519 keys on demand**, store the passphrase in macOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — never iCloud-synced).
- **Opt-in notifications** when a master drops, ControlPersist expires, your SSH cert is about to expire, or your imported host changed in `~/.ssh/config` from outside the app.

## Use

From the CLI (after `make install`):

```sh
bastion --version
bastion --help
# Full verb list lands in commits 5+ of the rollout:
#   bastion list / show / add / edit / remove
#   bastion connect <alias>
#   bastion master start|stop|check <alias>
#   bastion import --source zsh|bash|fish|known-hosts|ssh-config|all
#   bastion terminal list|set <id>
#   bastion config doctor
#   bastion uninstall
```

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

Release builds (Developer ID + hardened runtime + Sparkle keys) are maintainer-only.

## Trust model

Bastion runs as a non-sandboxed app with the hardened runtime enabled and the `com.apple.security.automation.apple-events` entitlement (required for AppleScript-driven terminal launches like Terminal.app / iTerm2). It does **not** install a privileged helper — SSH is entirely a user-space activity and Bastion has no root operations.

Auto-updates land via Sparkle 2 from a stable URL: `https://github.com/dbuskariol/bastion/releases/latest/download/appcast.xml`. The appcast is EdDSA-signed; the public key is baked into `Info.plist` (`SUPublicEDKey`). Sparkle refuses to install any update whose signature doesn't verify.

## License

MIT. See [LICENSE](LICENSE).
