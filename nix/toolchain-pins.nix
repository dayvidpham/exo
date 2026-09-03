# Toolchain pin drift check. Stub: issue #5 fills this file.
#
# Issue #5 must return:
#   checks.toolchain-pins - fails when two manifests disagree on a pin
#
# Manifests to compare: flake.nix (through moduleArgs, never as text),
# mise.toml, Cargo.toml, .github/workflows/ci.yml, and package.json.
#
# Argument set (moduleArgs from flake.nix):
#   pkgs lib self system pname version
#   rustVersion rustToolchain rustPlatform nodejs pnpm
#
# `rustVersion` arrives through moduleArgs, so this check never parses
# flake.nix as text. Read the pnpm pin from `pnpm.version` for the same reason.
_moduleArgs:

{ }
