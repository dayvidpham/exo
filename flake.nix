{
  description = "Exo development environment: pinned Rust, Node.js, and pnpm";

  # ============================================================
  # INPUTS
  # ============================================================

  inputs = rec {
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs = nixpkgs-unstable;
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # ============================================================
  # OUTPUTS
  # ============================================================

  outputs =
    inputs@{ self
    , nixpkgs
    , nixpkgs-stable
    , nixpkgs-unstable
    , flake-utils
    , rust-overlay
    , ...
    }:
    let
      # ==========================================================
      # PROJECT CONFIGURATION - edit this section for this project
      # ==========================================================

      # Package metadata.
      pname = "exo";

      # Version comes from the git short rev. This is a source build, not a
      # tagged release. self.shortRev exists only for a clean tree, so fall
      # back to dirtyShortRev, then to a literal, and a dirty tree still
      # evaluates.
      version = self.shortRev or self.dirtyShortRev or "dev";

      # Exact Rust release. This value must agree with:
      #   - mise.toml [tools].rust        (major.minor)
      #   - Cargo.toml rust-version       (major.minor)
      #   - .github/workflows/ci.yml      dtolnay/rust-toolchain pin
      #   - .github/workflows/integration.yml dtolnay/rust-toolchain pin
      # Issue #5 adds checks.toolchain-pins, which enforces this agreement.
      rustVersion = "1.95.0";

      # Exact pnpm release. It is read from package.json packageManager, so
      # there is one source of truth for the pnpm version.
      pnpmVersion =
        nixpkgs.lib.removePrefix "pnpm@"
          (builtins.fromJSON (builtins.readFile ./package.json)).packageManager;

      # Output hash of the pnpm tarball that pnpmVersion names. The source is a
      # flat fetchurl of
      # https://registry.npmjs.org/pnpm/-/pnpm-<version>.tgz
      # Bump this hash whenever packageManager in package.json changes: set it
      # to lib.fakeHash, run `nix develop`, and copy the reported `got:` hash.
      # Source of the value below: the fake hash workflow, for pnpm 10.26.2.
      pnpmHash = "sha256-Y7UKS6Fc3iAAbdul2eIf1iPiPwlMn2O7FfaGsOSWrtY=";

      # Output modules. Each module is a function of one argument set. It
      # returns a partial output set with optional `packages`, `checks`, and
      # `devShells` attributes. The list is static on purpose: no directory
      # scan, so evaluation stays pure and the file list is reviewable.
      modules = [
        ./nix/devshell.nix
        ./nix/rust.nix
        ./nix/node.nix
        ./nix/toolchain-pins.nix
        ./nix/firecracker.nix
      ];

      # ==========================================================
      # IMPLEMENTATION - you should not need to edit below here
      # ==========================================================

      mkOutputs = nixpkgs-channel:
        flake-utils.lib.eachDefaultSystem (system:
          let
            pkgs = import nixpkgs-channel {
              inherit system;
              overlays = [ rust-overlay.overlays.default ];
            };

            lib = pkgs.lib;

            # The pinned Rust toolchain. rust-overlay carries every stable
            # release, so this pin survives a nixpkgs bump. The default
            # component set already has cargo, clippy, and rustfmt.
            rustToolchain = pkgs.rust-bin.stable.${rustVersion}.default.override {
              extensions = [ "rust-src" "rust-analyzer" ];
            };

            # A rustPlatform built from the pinned toolchain. Issue #2 uses it
            # for buildRustPackage.
            rustPlatform = pkgs.makeRustPlatform {
              cargo = rustToolchain;
              rustc = rustToolchain;
            };

            # Node.js is pinned to major 22, the major that mise.toml names.
            # An exact patch pin would need a source build and is not worth it.
            nodejs = pkgs.nodejs_22;

            # pnpm is pinned to the exact packageManager version. pnpm 10 has
            # manage-package-manager-versions on by default, so a different
            # pnpm on PATH would download the named version and the shell would
            # not be frozen.
            pnpm = pkgs.pnpm_10.override {
              version = pnpmVersion;
              hash = pnpmHash;
            };

            # The one argument set every module receives.
            moduleArgs = {
              inherit pkgs lib self system pname version;
              inherit rustVersion rustToolchain rustPlatform nodejs pnpm;
            };
          in
          lib.foldl' lib.recursiveUpdate { } (map (m: import m moduleArgs) modules)
        );
    in
    mkOutputs nixpkgs;
}
