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

`nix flake check` runs `checks.rust` (`cargo fmt --check`,
`cargo clippy --workspace --all-targets -- -D warnings`, and
`cargo test --workspace --all-targets`) and `checks.toolchain-pins` (the
drift check across `flake.nix`, `mise.toml`, `Cargo.toml`,
`.github/workflows/ci.yml`, and `.github/workflows/integration.yml`).

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
| `pnpmDepsHash` | `nix/node.nix` | `pnpm-lock.yaml`, the pinned pnpm version, or the fetcher's `supportedArchitectures` list changes | `nix build .#node-modules` |

A stale `pnpmDepsHash` fails one of two ways, depending on whether the Nix
store already holds the old fetch:

- Cold store: the fetch runs again, and Nix stops it with
  `hash mismatch in fixed-output derivation`, printing `specified:` and
  `got:`. Copy the `got:` value into `nix/node.nix`.
- Warm store: the output path of a fixed-output derivation depends only on
  its declared hash and name, not on `pnpm-lock.yaml`. An edited lockfile
  resolves to the same, already-built path, so no fetch runs and no mismatch
  is reported at that step. The failure surfaces one step later, inside
  `packages.node-modules`, as `ERR_PNPM_NO_OFFLINE_TARBALL`: the prefetched
  store does not hold the tarball the new lockfile needs.

Both outcomes mean the same thing: the hash in `nix/node.nix` no longer
describes `pnpm-lock.yaml`.
