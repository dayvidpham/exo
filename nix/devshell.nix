# devShells.default: the everyday development environment for this repository.
#
# Returns: { devShells.default = <derivation>; }
#
# Argument set (moduleArgs from flake.nix):
#   pkgs lib self system pname version
#   rustVersion rustToolchain rustPlatform nodejs pnpm
#
# The shell hook never runs `pnpm install` or `cargo build`. The contributor
# runs those by hand. `pnpm install` installs the git hooks through
# scripts/setup-hooks.mjs, so it must stay an explicit action.
{ pkgs, lib, pname, rustToolchain, nodejs, pnpm, ... }:

{
  devShells.default = pkgs.mkShell {
    name = "${pname}-dev";

    packages = [
      # Pinned toolchains.
      rustToolchain
      nodejs
      pnpm
    ]
    ++ (with pkgs; [
      # Native build inputs the Cargo graph needs. Cargo.lock has
      # openssl-sys, aws-lc-sys, zstd-sys, libgit2-sys, and libz-sys.
      # The C compiler and linker come from stdenv, which mkShell provides.
      pkg-config
      openssl
      cmake

      # Runtime tools exo.sh calls.
      procps # pgrep, pkill
      gawk # awk
      gnused # sed
      git
      coreutils

      # Python is used only by exoharness/examples/gameboy-agent.
      # mise.toml pins 3.11.
      python311

      # Linters used by the checks and the git hooks.
      actionlint
      shellcheck
    ]);

    shellHook = ''
      echo "${pname} dev shell: rustc $(rustc --version | cut -d' ' -f2), node $(node --version), pnpm $(pnpm --version)"

      # Put the cargo debug output on PATH. This mirrors `_.path` in mise.toml,
      # so `exo` and `exo-scheduler-runner` resolve the same way under Nix and
      # under mise.
      export PATH="$PWD/target/debug:$PATH"

      # The pnpm on PATH already equals `packageManager` in package.json. This
      # stops pnpm from ever downloading another pnpm.
      export npm_config_manage_package_manager_versions=false

      [ -f .envrc.local ] && source .envrc.local || true
    '';
  };
}
