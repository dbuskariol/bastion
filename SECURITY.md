# Security Policy

Bastion reads and writes the user's SSH configuration and orchestrates the system `ssh` binary on the user's behalf. Reports of security issues are appreciated.

## Reporting a vulnerability

Email **security@dbuskariol.com** with the details. Please do not open public GitHub issues for security reports.

Include:
- The Bastion version (visible in the menu-bar popover footer).
- macOS version.
- A reproduction or proof of concept.
- Whether you've shared this with anyone else.

You should receive an acknowledgement within 7 days.

## Scope

In scope:
- Anything that lets a non-admin process modify Bastion-managed files in `~/.ssh/config.d/bastion.conf` or the sentinel block in `~/.ssh/config`.
- Bypass of EdDSA Sparkle update verification (signature, version downgrade, MITM on the appcast).
- AppleScript injection through host options (alias, RemoteCommand, ProxyCommand, IdentityFile path) reaching `osascript` without escaping.
- Keychain item exfiltration of stored SSH key passphrases.
- Command injection into the user's terminal of choice via `Connect`.

Out of scope:
- Bastion intentionally does not install a privileged helper. The non-sandboxed + hardened-runtime model is a documented design choice.
- The `com.apple.security.automation.apple-events` entitlement is required for AppleScript-driven terminal launches. Reports that it grants AppleScript send access are correct but already documented.
- The user's existing `~/.ssh/config` contents and the security of their existing SSH keys are out of scope; Bastion reads/respects what's already there but does not audit it.
