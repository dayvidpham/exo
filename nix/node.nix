# Node.js and pnpm build outputs. Stub: issue #3 fills this file.
#
# Issue #3 must return:
#   packages.node-modules - the frozen pnpm dependency graph, built offline
#                           from pnpm-lock.yaml
#   checks.typescript     - `pnpm check` and `pnpm format:check` against
#                           packages.node-modules
#
# Argument set (moduleArgs from flake.nix):
#   pkgs lib self system pname version
#   rustVersion rustToolchain rustPlatform nodejs pnpm
#
# The fetcher must run with `--ignore-scripts`. That is part of the contract:
# it stops the `prepare` script from running, so the build never touches git
# config.
#
# Suggested approach, not part of the contract: use `pnpm.fetchDeps` for the
# fixed-output derivation and `pnpmConfigHook` to install it.
_moduleArgs:

{ }
