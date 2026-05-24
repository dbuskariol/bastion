import Foundation
import BastionIdentifiers
import BastionCore

// Bastion CLI — entrypoint.
//
// Commit 1 ships a thin entrypoint that just resolves `--version` and
// `--help`. Real CLI verbs (list/show/add/edit/remove/connect/master/import/
// terminal/config/uninstall) land in later commits where they can dispatch
// into BastionCore's ConnectionEngine.

let usage = """
bastion: manage SSH connections from your menu bar

Usage:
  bastion --version
  bastion --help

This is a scaffold build. Full CLI verbs land in commits 5+ of the rollout.
"""

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "--version", "version":
    print(BastionVersion.value)
case nil, "--help", "-h":
    print(usage)
default:
    fputs("Unknown command: \(args.joined(separator: " "))\n", stderr)
    fputs(usage, stderr)
    exit(64)
}
