# Rust build outputs for issue #2.
#
# Returns:
#   packages.exo                  - the `exo` binary from crates/cli
#   packages.exo-scheduler-runner - the binary from exo/scheduler-runner
#   checks.rust                   - cargo fmt --check, cargo clippy -D warnings,
#                                   and cargo test --workspace --all-targets
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
  # include_str! or include_bytes!.
  #
  # Two places resolve paths against CARGO_MANIFEST_DIR, and both are covered.
  #
  # crates/firecracker-guest/build.rs reads five files at build time, relative
  # to its own manifest directory: Cargo.toml, src/main.rs, src/linux.rs, and
  # ../firecracker-protocol/Cargo.toml and ../firecracker-protocol/src/lib.rs.
  # The last two reach into a sibling crate, so `../crates` as a whole is what
  # covers them. Do not narrow this fileset to single crate directories: that
  # build script would then fail to find the protocol crate.
  #
  # crates/exoharness/src/sandbox_provider/firecracker_lima.rs walks two
  # directories up to the repository root and joins Cargo.toml onto it, to pass
  # to limactl. That is the macOS Lima flow and it reads the path at run time,
  # not at build time. The root Cargo.toml is in the fileset already.
  #
  # So nothing is missing from this list.
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
  # Set one fake hash at a time. Fixed-output derivations that declare the same
  # hash share one output path, so Nix builds only one of them and several
  # lib.fakeHash values at once report a single mismatch. Resolve them one by
  # one, or give each a different wrong value.
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

    # Selects which binaries the build phase produces and the install phase
    # puts in $out: the two this issue ships, and no other. It does not limit
    # what gets compiled overall. The check phase below runs
    # cargo test --workspace --all-targets, which compiles every workspace
    # member.
    cargoBuildFlags = [ "-p" "exo" "-p" "exo-scheduler-runner" ];

    nativeBuildInputs = with pkgs; [
      # openssl-sys, libgit2-sys, and libz-sys look their C libraries up
      # through pkg-config.
      pkg-config
      # aws-lc-sys drives its C build with cmake.
      cmake
    ];

    buildInputs = with pkgs; [
      # openssl-sys links against it. zstd-sys compiles its bundled C source
      # with the stdenv compiler and needs nothing here.
      openssl
    ];

    doCheck = true;

    # The same target selection as the `cargo test` step in
    # .github/workflows/ci.yml. --all-targets covers lib, bin, test, bench, and
    # example targets. It excludes doctests, so this build does not run them,
    # exactly as CI does not.
    cargoTestFlags = [ "--workspace" "--all-targets" ];

    nativeCheckInputs = with pkgs; [
      # Test-only dependency. The process bridge tests in
      # crates/exoharness/src/sandbox_provider/process_bridge.rs start the
      # bridge script with `python3` and fail with ENOENT when it is not on
      # PATH. mise.toml pins Python 3.11, so this uses the same major and
      # minor. The drift check in issue #5 compares rust, node, and pnpm only,
      # so nothing checks this pin automatically: match it to mise.toml by hand
      # when that file changes.
      python311
    ];

    # Flags for the test harness. They land after the `--` that cargoCheckHook
    # adds, so the test binary reads them.
    #
    # This is a workaround, not a fix. The test
    # sandbox::tests::docker_warm_sandbox_lookup_uses_docker_ps_filters writes a
    # fake `docker` shell script into a temporary directory and then runs it.
    # With parallel test threads it failed here with
    # `find warm sandbox: Text file busy (os error 26)`, because another thread
    # forked while the script file was still open for writing and the child
    # inherited the descriptor. One thread hides that race; it does not remove
    # it, and .github/workflows/ci.yml still runs the suite in parallel.
    #
    # Issue #14 tracks the fix in the test itself. Delete this flag when #14
    # lands, so this build runs the suite in parallel like CI does.
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
    # This is a plain attribute update. It must not become overrideAttrs, and it
    # must not become lib.addMetaAttrs either. mkDerivation turns
    # meta.mainProgram into the NIX_MAIN_PROGRAM build variable, so any route
    # that goes through overrideAttrs produces a second derivation and builds
    # the whole workspace again. lib.addMetaAttrs takes that route: it calls
    # drv.overrideAttrs whenever the derivation has it (nixpkgs lib/meta.nix,
    # addMetaAttrs), and only falls back to a plain update otherwise. Using it
    # here gave two store paths, one per attribute. The `//` update keeps
    # drvPath and outPath from `exo`, so both attributes stay one build.
    #
    # Apply build overrides to packages.exo, not here. .overrideAttrs does work
    # on this attribute, but it starts from `exo` and drops the meta set below,
    # so it returns a second full build of the workspace whose mainProgram is
    # `exo`, not `exo-scheduler-runner`.
    exo-scheduler-runner = exo // {
      meta = exo.meta // {
        description = "Exo scheduler runner";
        mainProgram = "exo-scheduler-runner";
      };
    };
  };

  checks = {
    # The same three commands as the rust-tests job in
    # .github/workflows/ci.yml: cargo fmt --all -- --check,
    # cargo clippy --workspace --all-targets, and
    # cargo test --workspace --all-targets. .githooks/pre-push runs the clippy
    # command only, so this check is the wider of the two.
    #
    # This derivation runs the first two itself. It gets the third by depending
    # on packages.exo, whose doCheck runs the tests: the install phase writes
    # that package's store path into $out, and the reference is what creates the
    # dependency. Two consequences follow, both deliberate:
    #
    #   - That one line is the only reason `nix flake check` runs the workspace
    #     tests. `nix flake check` builds checks, not packages, so removing the
    #     line silently drops the tests from the check.
    #   - It orders the work. Nix builds packages.exo first, so fmt and clippy
    #     wait behind the full package build and its tests instead of running
    #     beside them. That trades wall clock for one fewer compile of the
    #     workspace: two in total, not three.
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

      # Depends on packages.exo, so the workspace tests run. See the block
      # comment above before changing this line.
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
