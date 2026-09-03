---
title: Installation
description: One setup script to a running agent.
---

# Installation

## Prerequisites

The setup script checks for these and prints per-platform install
instructions for anything missing:

- **git**
- **Node.js 22+ and pnpm**
- **Rust** (via [rustup](https://rustup.rs/))
- **Docker** — running, for the agent's sandbox

You'll also need an **OpenAI API key**.

Instead of installing Node.js, pnpm, and Rust yourself, you can get all
three, pinned to the exact versions this repository builds against, from
the repository's Nix flake. See
[Using the Nix flake](#using-the-nix-flake) below. That path needs
[Nix](https://nixos.org/download) with flakes enabled, and optionally
[direnv](https://direnv.net/).

## Run the setup script

```bash
curl -fsSL https://raw.githubusercontent.com/exoharness/exo/main/setup.sh -o setup.sh
bash setup.sh
```

The script installs Exo into the current directory and walks you through
everything:

1. Clones the repository and builds the `exo` CLI.
2. Asks for your OpenAI API key (stored in a `.env` file with `600`
   permissions, then registered in exo's secret store).
3. Asks for your name and your agent's name, and writes a local profile at
   `.exo/exo-profile.md` (git-ignored — machine-specific instructions
   live here).
4. Starts the canonical agent: a sandbox (Ubuntu 24.04 in Docker), the task
   scheduler, and the ExoChat adapter.

When it finishes, two things happen:

- It prints a URL like
  `https://exoharness.ai/chat?role=user&c=...#k=...` — a minimal remote chat
  interface to your agent. Open it in any browser, including your phone.
- It drops you into a local REPL where you can talk to the agent directly.

Head to [Your First Session](./first-session) for what to try next.

## Installing just the CLI

If you want the `exo` CLI without the canonical agent — to build your own
harness from scratch or script against the exoharness — install it from a
checkout with cargo:

```bash
git clone https://github.com/exoharness/exo
cd exo
cargo install --path crates/cli --locked
exo --help
```

This places a release build at `~/.cargo/bin/exo` (on your `PATH` via
rustup). See [Using the CLI Directly](./quick-start) to register a model
and start a bare REPL, and run `pnpm install` if you'll use TypeScript
harnesses.

::: info
  Hacking on exo itself? Use a debug build: `cargo build -p exo`, then invoke
  it as `./target/debug/exo`.
:::

## Using the Nix flake

The repository ships a `flake.nix` that pins Node.js, pnpm, and Rust to the
exact versions this repository builds against. It is a second way to get a
toolchain, alongside the [Prerequisites](#prerequisites) list and the setup
script in [Quick Start](https://github.com/exoharness/exo#quick-start). It does not change
what the setup script does.

```bash
git clone https://github.com/exoharness/exo
cd exo
nix develop
```

`nix develop` opens a shell with the pinned toolchain on `PATH` and prints
their versions. Run the [Quick Start](https://github.com/exoharness/exo#quick-start)
commands inside that shell, or prefix any command with `nix develop -c`, for
example `nix develop -c ./exo.sh`.

With [direnv](https://direnv.net/) installed, run `direnv allow` once in the
repository root instead. The committed `.envrc` loads the same shell
automatically on every `cd` into the directory.

See [Development](../development/index.md#using-the-nix-flake) for
`nix flake check`, the package builds, and the hash bump procedure.
