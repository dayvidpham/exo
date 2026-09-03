# Firecracker host tooling and guest runtime. Stub: issue #7 fills this file.
#
# Issue #7 must return, on Linux systems only:
#   devShells.firecracker         - devShells.default plus the Firecracker host
#                                   tools from the 1.16.1 release archive
#   packages.exo-firecracker-guest - the static guest runtime from
#                                   crates/firecracker-guest
# On every other system it must return { }.
#
# Argument set (moduleArgs from flake.nix):
#   pkgs lib self system pname version
#   rustVersion rustToolchain rustPlatform nodejs pnpm
#
# Gate on `lib.hasSuffix "-linux" system`. Fetch the release archive with
# `fetchurl` and the SHA-256 values in support/firecracker/README.md.
_moduleArgs:

{ }
