{
  description = "Exo development environment: pinned Rust, Node.js, and pnpm";

  # ============================================================
  # INPUTS
  # ============================================================

  inputs = {
    # Kept so `mkOutputs` can be pointed at the stable channel in one place.
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    # `nixpkgs` is the channel the outputs are built from. It follows
    # nixpkgs-unstable rather than repeating the URL, so flake.lock holds one
    # node for the two names instead of two nodes that must agree.
    nixpkgs.follows = "nixpkgs-unstable";
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
    { self
    , nixpkgs
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

      # Exact Rust release. checks.toolchain-pins, added by issue #5, compares
      # this value across six manifests:
      #   - flake.nix                          (this file)
      #   - mise.toml [tools].rust             (major.minor)
      #   - Cargo.toml rust-version            (major.minor)
      #   - .github/workflows/ci.yml           dtolnay/rust-toolchain pin
      #   - .github/workflows/integration.yml  dtolnay/rust-toolchain pin
      #   - package.json                       (for the pnpm pin)
      # The Node.js major is read from mise.toml and .github/workflows/ci.yml.
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

            # Node.js is pinned to major 22 only. mise.toml pins the exact
            # patch, 22.15.0, but `nodejs_22` gives whatever patch the locked
            # nixpkgs carries. An exact patch pin would need a source build and
            # is not worth it. So the drift check in issue #5 compares the
            # Node.js major only, not the full version.
            nodejs = pkgs.nodejs_22;

            # pnpm is pinned to the exact packageManager version. pnpm 10 has
            # manage-package-manager-versions on by default, so a pnpm on PATH
            # that differs from packageManager would download the named version
            # and the shell would not be frozen. The dev shell also exports
            # npm_config_manage_package_manager_versions=false, which turns that
            # behaviour off outright.
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
