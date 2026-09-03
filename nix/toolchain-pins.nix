# Toolchain pin drift check.
#
# Returns:
#   checks.toolchain-pins           - fails when two manifests disagree on a
#                                     pin, checked against the repository's
#                                     own mise.toml, Cargo.toml,
#                                     .github/workflows/ci.yml, and
#                                     package.json.
#   checks.toolchain-pins-fixtures  - runs the same script against the golden
#                                     cases under nix/fixtures/toolchain-pins.
#
# Argument set (moduleArgs from flake.nix):
#   pkgs lib self system pname version
#   rustVersion rustToolchain rustPlatform nodejs pnpm
#
# Contract: this file never parses flake.nix as text. `rustVersion`, the
# flake's own rust pin, arrives through moduleArgs above and is the source of
# truth the script compares mise.toml, Cargo.toml, and ci.yml against.
{ pkgs, lib, self, rustVersion, ... }:

let
  script = ./toolchain-pins.sh;

  toolBuildInputs = [ pkgs.bash pkgs.gawk pkgs.gnused pkgs.gnugrep ];

  # Reads the three manifests Nix has a parser for (mise.toml and Cargo.toml
  # through builtins.fromTOML, package.json through builtins.fromJSON) and
  # builds the environment nix/toolchain-pins.sh runs with. ciYml is passed
  # straight through as a path: the script parses .github/workflows/ci.yml
  # itself, because Nix has no YAML parser in the standard library.
  mkEnv =
    { miseToml, cargoToml, packageJson, ciYml, rustVersion }:
    let
      mise = builtins.fromTOML (builtins.readFile miseToml);
      cargo = builtins.fromTOML (builtins.readFile cargoToml);
      package = builtins.fromJSON (builtins.readFile packageJson);
    in
    {
      RUST_VERSION = rustVersion;
      # String interpolation ("${path}"), not toString, on every path below:
      # toString on a Nix path drops its store context, so the sandboxed
      # build would not see the file the value names.
      MISE_TOML_PATH = "${miseToml}";
      MISE_RUST = mise.tools.rust;
      MISE_NODE = mise.tools.nodejs;
      MISE_PNPM = mise.tools.pnpm;
      CARGO_TOML_PATH = "${cargoToml}";
      CARGO_RUST = cargo.workspace.package."rust-version";
      PACKAGE_JSON_PATH = "${packageJson}";
      PACKAGE_PNPM = lib.removePrefix "pnpm@" package.packageManager;
      CI_YML_PATH = "${ciYml}";
    };

  # checks.toolchain-pins: the drift check on the repository's own manifests.
  toolchainPins =
    pkgs.runCommand "toolchain-pins-check"
      (
        (mkEnv {
          miseToml = "${self}/mise.toml";
          cargoToml = "${self}/Cargo.toml";
          packageJson = "${self}/package.json";
          ciYml = "${self}/.github/workflows/ci.yml";
          inherit rustVersion;
        })
        // {
          nativeBuildInputs = toolBuildInputs;
        }
      )
      ''
        bash ${script} | tee $out
      '';

  # nix/fixtures/toolchain-pins/<case>/ holds copies of the four manifests
  # this check parses, plus a file named `expected` containing `pass` or
  # `fail`. The case list is static: no directory scan discovers new cases.
  # `driftFile` names the manifest the case's drift lives in, so the fixture
  # check can assert the failure message names it.
  fixtureCases = [
    { name = "agree"; expectPass = true; }
    { name = "rust-drift"; expectPass = false; driftFile = "ci.yml"; }
    { name = "node-drift"; expectPass = false; driftFile = "ci.yml"; }
    { name = "pnpm-drift"; expectPass = false; driftFile = "mise.toml"; }
  ];

  fixtureDir = case: ./fixtures/toolchain-pins + "/${case.name}";

  mkFixtureCheck =
    case:
    let
      dir = fixtureDir case;
      env = mkEnv {
        miseToml = dir + "/mise.toml";
        cargoToml = dir + "/Cargo.toml";
        packageJson = dir + "/package.json";
        ciYml = dir + "/ci.yml";
        inherit rustVersion;
      };
      expectPassStr = if case.expectPass then "pass" else "fail";
      driftFile = case.driftFile or "";
    in
    pkgs.runCommand "toolchain-pins-fixture-${case.name}"
      (
        env
        // {
          nativeBuildInputs = toolBuildInputs;
          inherit expectPassStr driftFile;
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

        if [ "$expectPassStr" = fail ] && [ -n "$driftFile" ] && ! grep -q "$driftFile" output.log; then
          echo "case $caseName: the failure message did not name $driftFile" >&2
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
