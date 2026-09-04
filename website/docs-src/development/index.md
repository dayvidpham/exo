---
title: Development
description: Building, testing, CI, and contribution conventions.
---

# Development

::: warning Under construction
  This section is a work in progress and not yet complete.
:::

Building, testing, CI, and contribution conventions.

```bash
pnpm check
cargo test --workspace --all-targets
```

Install the Git hooks once:

```bash
pnpm prepare
```

## Using the Nix flake

The repository ships a `flake.nix` that pins Node.js, pnpm, and Rust. See
[Installation](../getting-started/installation.md#using-the-nix-flake) for
how to enter the shell:

```bash
nix develop
```

Run the same checks and builds this repository's CI runs, through the
flake:

```bash
nix flake check
nix build .#exo
nix build .#node-modules
```

`nix flake check` runs `checks.rust` (`cargo fmt --all -- --check`,
`cargo clippy --workspace --all-targets -- -D warnings`, and
`cargo test --workspace --all-targets`), `checks.toolchain-pins` (the drift
check across `flake.nix`, `mise.toml`, `Cargo.toml`,
`.github/workflows/ci.yml`, and `.github/workflows/integration.yml`), and
`checks.typescript` (`pnpm check` and `pnpm format:check` against
`packages.node-modules`).

`nix build .#exo` builds the `exo` binary with `rustPlatform.buildRustPackage`.
`nix build .#node-modules` installs the pnpm dependency graph offline, from a
store that `pkgs.fetchPnpmDeps` prefetches as a fixed-output derivation.

### `pnpm install` and the Git hooks

A plain `pnpm install` runs the `prepare` script
(`node scripts/setup-hooks.mjs`), which sets `core.hooksPath` to
`.githooks`. `nix build .#node-modules` never does this. Both the fetch and
the offline install it runs pass `--ignore-scripts`, so `prepare` never
runs, and this path never touches `core.hooksPath`.

### Hash bump procedure

Three Nix hashes need a manual bump when the value they were computed from
changes. All three use the same fake hash workflow: set the value to
`lib.fakeHash`, run the build named below, and copy the reported `got:` hash
back into the flake.

| Hash | File | Bump when | Build to run |
| --- | --- | --- | --- |
| `cargoLock.outputHashes` (one entry per git source) | `nix/rust.nix` | a git `rev` in `Cargo.lock` changes | `nix build .#exo` |
| `pnpmHash` | `flake.nix` | `packageManager` in `package.json` changes | `nix develop` |
| `pnpmDepsHash` | `nix/node.nix` | `pnpm-lock.yaml`, the pinned pnpm version, the fetcher's `supportedArchitectures` list, or `fetcherVersion` changes | `nix build .#node-modules` |

pnpm's offline install finds a package through its store index file, named
`v10/index/<first 2 hex>/<next 62 hex>-<name>@<version>.json`. Those 64 hex
characters are the first 32 bytes of the package's sha512 integrity digest.
So `pnpmDepsHash` goes stale when the resolved set of packages changes, or
when an `integrity:` value changes inside those first 32 bytes, roughly the
first 43 characters of the base64 body. An edit confined to the last 32
bytes leaves the index file name alone and still passes on a warm store:
the hash guards the resolved set of packages, not every byte of
`pnpm-lock.yaml`.

A resolved-set change fails on a warm store as
`ERR_PNPM_NO_OFFLINE_TARBALL`, naming the missing package. On a cold store,
or under `nix build .#node-modules.pnpmDeps --rebuild`, the fetch runs
again and Nix stops it with `hash mismatch in fixed-output derivation`,
printing `specified:` and `got:`. Copy the `got:` value into
`nix/node.nix`.

An integrity-only change inside the first 32 bytes fails on a warm store
the same way, as `ERR_PNPM_NO_OFFLINE_TARBALL`. On a cold store the fetch
runs, and pnpm rejects the wrong integrity itself with
`ERR_PNPM_TARBALL_INTEGRITY`, before Nix ever compares the declared hash.
