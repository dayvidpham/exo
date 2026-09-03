# Rust build outputs. Stub: issue #2 fills this file.
#
# Issue #2 must return:
#   packages.exo                  - the `exo` binary from crates/cli
#   packages.exo-scheduler-runner - the binary from exo/scheduler-runner
#   checks.rust                   - cargo fmt --check, cargo clippy -D warnings,
#                                   and cargo test --workspace
#
# Argument set (moduleArgs from flake.nix):
#   pkgs lib self system pname version
#   rustVersion rustToolchain rustPlatform nodejs pnpm
#
# Suggested approach, not part of the contract: use
# `rustPlatform.buildRustPackage` with `cargoLock.lockFile = ../Cargo.lock`.
# Cargo.lock has three git sources, so `cargoLock.outputHashes` needs one entry
# for each of them. A different builder is fine as long as the attribute names
# above stay the same.
_moduleArgs:

{ }
