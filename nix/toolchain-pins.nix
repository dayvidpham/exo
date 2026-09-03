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
# Contract: this check never parses flake.nix as text. `rustVersion` arrives
# through moduleArgs for exactly that reason.
#
# Suggested approach, not part of the contract: read the pnpm pin from
# `pnpm.version`, which avoids a second text parse.
_moduleArgs:

{ }
