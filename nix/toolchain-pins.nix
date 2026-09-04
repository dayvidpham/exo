# Toolchain pin drift check.
#
# Returns:
#   checks.toolchain-pins           - fails when two manifests disagree on a
#                                     pin, checked against the repository's
#                                     own mise.toml, Cargo.toml,
#                                     .github/workflows/ci.yml,
#                                     .github/workflows/integration.yml, and
#                                     package.json.
#   checks.toolchain-pins-fixtures  - runs the same script against the golden
#                                     cases under nix/fixtures/toolchain-pins,
#                                     listed below as fixtureCases.
#
# Argument set (moduleArgs from flake.nix):
#   pkgs lib self system pname version
#   rustVersion rustToolchain rustPlatform nodejs pnpm
#
# Contract: this file never parses flake.nix as text. `rustVersion`, the
# flake's own rust pin, arrives through moduleArgs above and is the source of
# truth the script compares mise.toml, Cargo.toml, ci.yml, and
# integration.yml against. `pnpm`
# also arrives through moduleArgs: `pnpm.version` is the same value flake.nix
# already read out of package.json to build that derivation, so the real
# check does not read package.json a second time. `nodejs.version` is the
# flake's own Node.js pin, compared against mise.toml so the dev shell's
# Node.js major cannot drift from the manifest silently.
{ pkgs, lib, self, rustVersion, nodejs, pnpm, ... }:

let
  script = ./toolchain-pins.sh;

  toolBuildInputs = [ pkgs.bash pkgs.gawk pkgs.gnused pkgs.gnugrep ];

  # Reads mise.toml and Cargo.toml, the two manifests left for this function
  # to parse (builtins.fromTOML), and builds the environment
  # nix/toolchain-pins.sh runs with. `ciYml` and `integrationYml` are passed
  # straight through as paths: the script parses .github/workflows/ci.yml and
  # .github/workflows/integration.yml itself, because Nix has no YAML parser
  # in the standard library. `ciYmlLabel`, `integrationYmlLabel`,
  # `expectedRust`, and `expectedNode` are parameters, not values closed over
  # from the outer scope: a fixture case supplies its own fixed rust and
  # Node.js pins (see fixtureCases below) so the golden cases stay hermetic,
  # independent of the live flake.nix and nodejs.version values.
  mkEnv =
    {
      miseToml,
      cargoToml,
      ciYml,
      ciYmlLabel,
      integrationYml,
      integrationYmlLabel,
      expectedRust,
      expectedNode,
      pnpmVersion,
    }:
    let
      mise = builtins.fromTOML (builtins.readFile miseToml);
      cargo = builtins.fromTOML (builtins.readFile cargoToml);
    in
    {
      RUST_VERSION = expectedRust;
      NODEJS_VERSION = expectedNode;
      MISE_TOML_LABEL = "mise.toml";
      MISE_RUST = mise.tools.rust;
      MISE_NODE = mise.tools.nodejs;
      MISE_PNPM = mise.tools.pnpm;
      CARGO_TOML_LABEL = "Cargo.toml";
      CARGO_RUST = cargo.workspace.package."rust-version";
      PACKAGE_JSON_LABEL = "package.json";
      PACKAGE_PNPM = pnpmVersion;
      # String interpolation ("${path}"), not toString, on the ci.yml and
      # integration.yml paths: toString on a Nix path drops its store
      # context, so the sandboxed build would not see the file the value
      # names.
      CI_YML_PATH = "${ciYml}";
      CI_YML_LABEL = ciYmlLabel;
      INTEGRATION_YML_PATH = "${integrationYml}";
      INTEGRATION_YML_LABEL = integrationYmlLabel;
    };

  # checks.toolchain-pins: the drift check on the repository's own manifests.
  toolchainPins =
    pkgs.runCommand "toolchain-pins-check"
      (
        (mkEnv {
          miseToml = "${self}/mise.toml";
          cargoToml = "${self}/Cargo.toml";
          ciYml = "${self}/.github/workflows/ci.yml";
          ciYmlLabel = ".github/workflows/ci.yml";
          integrationYml = "${self}/.github/workflows/integration.yml";
          integrationYmlLabel = ".github/workflows/integration.yml";
          expectedRust = rustVersion;
          expectedNode = nodejs.version;
          pnpmVersion = pnpm.version;
        })
        // {
          nativeBuildInputs = toolBuildInputs;
        }
      )
      ''
        bash ${script} | tee $out
      '';

  # nix/fixtures/toolchain-pins/<case>/ holds copies of mise.toml, Cargo.toml,
  # package.json, ci.yml, and integration.yml. The case list below is the
  # single source of truth for the expected outcome: no per-case "expected"
  # file, and no directory scan discovers new cases.
  #
  # `rustVersion` and `nodeVersion` are fixed per case, not the live
  # flake.nix pins, so a case stays hermetic even if the flake's own pins
  # change later. `driftTool` and `driftFile` name the tool and the
  # manifest a failing case's drift lives in, so the fixture check can
  # assert the failure message names both, not just any file.
  fixtureCases = [
    { name = "agree"; expectPass = true; rustVersion = "1.95.0"; nodeVersion = "22.22.3"; }
    {
      name = "rust-drift";
      expectPass = false;
      rustVersion = "1.95.0";
      nodeVersion = "22.22.3";
      driftTool = "rust";
      driftFile = "ci.yml";
    }
    {
      # mise.toml states a major.minor rust value (no patch) that disagrees
      # with the case's rustVersion, driving the major.minor branch of
      # compare_rust, not the major.minor.patch branch rust-drift exercises.
      name = "rust-drift-nopatch";
      expectPass = false;
      rustVersion = "1.95.0";
      nodeVersion = "22.22.3";
      driftTool = "rust";
      driftFile = "mise.toml";
    }
    {
      name = "node-drift";
      expectPass = false;
      rustVersion = "1.95.0";
      nodeVersion = "22.22.3";
      driftTool = "node";
      driftFile = "ci.yml";
    }
    {
      name = "pnpm-drift";
      expectPass = false;
      rustVersion = "1.95.0";
      nodeVersion = "22.22.3";
      driftTool = "pnpm";
      driftFile = "mise.toml";
    }
    {
      # Only integration.yml drifts; mise.toml, Cargo.toml, and ci.yml all
      # agree with the case's rustVersion.
      name = "integration-rust-drift";
      expectPass = false;
      rustVersion = "1.95.0";
      nodeVersion = "22.22.3";
      driftTool = "rust";
      driftFile = "integration.yml";
    }
  ];

  fixtureDir = case: ./fixtures/toolchain-pins + "/${case.name}";

  mkFixtureCheck =
    case:
    let
      dir = fixtureDir case;
      packageJson = dir + "/package.json";
      # Each fixture case supplies its own package.json, so the pnpm pin
      # for a fixture is read from it directly. This is different from the
      # real check above: there, pnpm.version is already the live,
      # already-parsed value, and a fixture has no such live derivation to
      # read from.
      pnpmVersion = lib.removePrefix "pnpm@" (builtins.fromJSON (builtins.readFile packageJson)).packageManager;
      env = mkEnv {
        miseToml = dir + "/mise.toml";
        cargoToml = dir + "/Cargo.toml";
        ciYml = dir + "/ci.yml";
        ciYmlLabel = "ci.yml";
        integrationYml = dir + "/integration.yml";
        integrationYmlLabel = "integration.yml";
        expectedRust = case.rustVersion;
        expectedNode = case.nodeVersion;
        inherit pnpmVersion;
      };
      expectPassStr = if case.expectPass then "pass" else "fail";
      driftTool = case.driftTool or "";
      driftFile = case.driftFile or "";
    in
    pkgs.runCommand "toolchain-pins-fixture-${case.name}"
      (
        env
        // {
          nativeBuildInputs = toolBuildInputs;
          inherit expectPassStr driftTool driftFile;
          caseName = case.name;
        }
      )
      ''
        set +e
        bash ${script} > output.log 2>&1
        status=$?
        set -e
        cat output.log

        if [ "$expectPassStr" = pass ] && [ "$status" -ne 0 ]; then
          echo "case $caseName: expected the check to pass, it failed" >&2
          exit 1
        fi

        if [ "$expectPassStr" = fail ] && [ "$status" -eq 0 ]; then
          echo "case $caseName: expected the check to fail, it passed" >&2
          exit 1
        fi

        if [ "$expectPassStr" = fail ] && [ -n "$driftTool" ] && [ -n "$driftFile" ] \
          && ! grep -E "drift \($driftTool\)" output.log | grep -F "$driftFile" > /dev/null; then
          echo "case $caseName: the failure message did not name $driftTool drift in $driftFile" >&2
          exit 1
        fi

        echo "case $caseName: ok (expected $expectPassStr)" > $out
      '';

  # checks.toolchain-pins-fixtures: runs every golden case and reports each.
  toolchainPinsFixtures =
    pkgs.runCommand "toolchain-pins-fixtures-check" { }
      ''
        ${lib.concatMapStringsSep "\n" (case: "cat ${mkFixtureCheck case}") fixtureCases}
        touch $out
      '';
in
{
  checks = {
    toolchain-pins = toolchainPins;
    toolchain-pins-fixtures = toolchainPinsFixtures;
  };
}
