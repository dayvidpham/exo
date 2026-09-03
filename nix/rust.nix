# Rust build outputs for issue #2.
#
# Returns:
#   packages.exo                  - the `exo` binary from crates/cli
#   packages.exo-scheduler-runner - the binary from exo/scheduler-runner
#   checks.rust                   - cargo fmt --check, cargo clippy -D warnings,
#                                   and cargo test --workspace
#
# Argument set (moduleArgs from flake.nix):
#   pkgs lib self system pname version
#   rustVersion rustToolchain rustPlatform nodejs pnpm
#
# One derivation builds both binaries in one cargo invocation. The workspace is
# large, so a second full build only to relabel one binary would double the
# build time for no gain. packages.exo-scheduler-runner is the same derivation
# with a different meta.mainProgram.
{ pkgs, lib, pname, version, rustToolchain, rustPlatform, ... }:

let
  # Only the files cargo reads. node_modules, target, website, and .exo stay
  # out, so an edit to any of them does not rebuild the Rust tree.
  # Every path below is either a workspace manifest, a workspace member, or a
  # file a member reads at build time. No Rust source in this tree uses
  # include_str!, include_bytes!, or env!("CARGO_MANIFEST_DIR") to read a file
  # outside crates/ or exo/scheduler-runner/, so the list is complete.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      # clippy.toml sets too-many-arguments-threshold. checks.rust reuses this
      # source and needs it, and cargo reads it for the package build too.
      ../clippy.toml
      ../crates
      ../exo/scheduler-runner
    ];
  };

  # Cargo.lock pins three git sources by rev. importCargoLock needs one entry
  # per git package, keyed `<crate-name>-<crate-version>`. Packages that share
  # one repository share one hash.
  #
  # Fake hash workflow: set a value to lib.fakeHash, run `nix build .#exo`, and
  # copy the reported `got:` hash back here. Recompute a hash only when the
  # matching git `rev` in Cargo.lock changes.
  #
  # Source of every value below: the fake hash workflow, run on 2026-09-03
  # against the revs in Cargo.lock at that time.
  #
  #   braintrustdata/lingua.git        rev 3ab9bcc9b58688be37216e9ab0b3d8362d185cfb
  #   braintrustdata/braintrust-sdk-rust
  #                                    rev 55dcefd989b6038edb5ef8dfc438384340d5f4ae
  #   braintrustdata/serde-json.git    rev 905b790b50e8922370f3e73ef93d7d5fb7010edc
  linguaHash = "sha256-vKvBpNIe2hvZxUOFer1rrmfpaouffaZYWv70DqDxReQ=";
  braintrustSdkHash = "sha256-OZCuwMFAYXqhGNpTXRQ7JPCfaZKNevRxoeZ17KxOXQE=";
  braintrustSerdeJsonHash = "sha256-8pMAb+Aem47H+akPHcBcvS+aPbSUM4xPjCH5GzZl4uQ=";

  outputHashes = {
    # braintrustdata/lingua.git
    "big_serde_json-0.1.0" = linguaHash;
    "braintrust-llm-router-0.1.0" = linguaHash;
    "lingua-0.1.0" = linguaHash;
    # braintrustdata/braintrust-sdk-rust
    "braintrust-sdk-rust-0.1.0-alpha.2" = braintrustSdkHash;
    # braintrustdata/serde-json.git
    "braintrust_serde_json-1.0.145" = braintrustSerdeJsonHash;
  };

  exo = rustPlatform.buildRustPackage {
    inherit pname version src;

    cargoLock = {
      lockFile = ../Cargo.lock;
      inherit outputHashes;
    };

    # Build only the two binaries this issue ships. The other workspace members
    # are still compiled as dependencies where a binary needs them.
    cargoBuildFlags = [ "-p" "exo" "-p" "exo-scheduler-runner" ];

    nativeBuildInputs = with pkgs; [
      # openssl-sys and libgit2-sys look their C libraries up through pkg-config.
      pkg-config
      # aws-lc-sys drives its C build with cmake.
      cmake
    ];

    buildInputs = with pkgs; [
      # openssl-sys links against it. libsqlite3-sys and zstd-sys build their
      # bundled C source with the stdenv compiler and need nothing here.
      openssl
    ];

    doCheck = true;
    cargoTestFlags = [ "--workspace" ];

    # Test-only dependency. The process bridge tests in
    # crates/exoharness/src/sandbox_provider/process_bridge.rs start the bridge
    # script with `python3` and fail with ENOENT when it is not on PATH.
    # mise.toml pins Python 3.11, so the check uses the same major and minor.
    nativeCheckInputs = [ pkgs.python311 ];

    # Flags for the test harness. They land after the `--` that cargoCheckHook
    # adds, so the test binary reads them.
    #
    # The whole workspace test run takes a few seconds, so one thread costs
    # little. It keeps
    # sandbox::tests::docker_warm_sandbox_lookup_uses_docker_ps_filters
    # passing: that test writes a fake `docker` shell script into a temporary
    # directory and then runs it. With parallel test threads the run failed in
    # the sandbox with `Text file busy`, because another thread forked while the
    # script file was still open for writing and the child inherited the
    # descriptor. One thread removes that race, so no test has to be skipped.
    #
    # No test is skipped. Tests marked #[ignore] are already skipped by cargo:
    # they need the network, a container daemon, or a real sandbox provider.
    checkFlags = [ "--test-threads=1" ];

    meta = {
      description = "Exo command line interface";
      license = lib.licenses.mit;
      mainProgram = "exo";
      platforms = lib.platforms.unix;
    };
  };
in
{
  packages = {
    inherit exo;

    # The same derivation as packages.exo, relabelled. Only meta changes, so
    # `nix run` and `nix build` name the scheduler runner instead of the CLI and
    # both attributes resolve to one store path.
    #
    # This is a plain attribute update, not overrideAttrs. mkDerivation turns
    # meta.mainProgram into the NIX_MAIN_PROGRAM build variable, so an
    # overrideAttrs here would produce a second derivation and build the
    # workspace twice. The update keeps drvPath and outPath from `exo`.
    exo-scheduler-runner = exo // {
      meta = exo.meta // {
        description = "Exo scheduler runner";
        mainProgram = "exo-scheduler-runner";
      };
    };
  };

  checks = {
    # The same three commands as .github/workflows/ci.yml and .githooks/pre-push:
    # cargo fmt --all -- --check, cargo clippy --workspace --all-targets, and
    # cargo test --workspace.
    #
    # This derivation runs the first two. The install phase below records the
    # packages.exo store path, which makes this check depend on that package,
    # whose doCheck runs the workspace tests. So `nix flake check` covers all
    # three commands and the workspace is compiled twice, not three times.
    #
    # It reuses the package source and its vendored cargo dependencies, so it
    # needs no extra fetching.
    rust = exo.overrideAttrs (old: {
      pname = "${pname}-rust-checks";

      nativeBuildInputs = old.nativeBuildInputs ++ [ rustToolchain ];

      # Each command is echoed first. A clean `cargo fmt` prints nothing, so
      # without the echo a reader cannot tell from the log that it ran.
      buildPhase = ''
        runHook preBuild
        echo "running: cargo fmt --all -- --check"
        cargo fmt --all -- --check
        echo "running: cargo clippy --workspace --all-targets -- -D warnings"
        cargo clippy --workspace --all-targets -- -D warnings
        runHook postBuild
      '';

      doCheck = false;

      # Writing the store path puts a reference to packages.exo in the output,
      # so this check cannot succeed unless that package, and therefore
      # cargo test --workspace, succeeded first.
      installPhase = ''
        runHook preInstall
        echo "${exo}" > $out
        runHook postInstall
      '';

      # No binary is installed, so mainProgram would name a file that does
      # not exist.
      meta = (removeAttrs old.meta [ "mainProgram" ]) // {
        description = "Exo Rust format and lint checks";
      };
    });
  };
}
