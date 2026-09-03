#!/usr/bin/env bash
# Toolchain pin drift check.
#
# Compares the Rust, Node.js, and pnpm pins across five manifests: flake.nix,
# mise.toml, Cargo.toml, .github/workflows/ci.yml, and package.json.
#
# Nix parses flake.nix, mise.toml, Cargo.toml, and the pnpm pin before this
# script runs, with `rustVersion` and `pnpm.version` (both passed through
# moduleArgs) and builtins.fromTOML. Their already-extracted values arrive
# below as environment variables. This script parses
# .github/workflows/ci.yml itself, because Nix has no YAML parser in the
# standard library. The parse is anchored to the exact step names
# "Set up Rust", "Set up Node.js", and "Set up pnpm".
#
# Comparison rules:
#   rust: the number of dot-separated fields in the manifest's own value
#         decides the rule. A value with a patch, such as ci.yml's
#         "1.95.0", compares major.minor.patch. A value with no patch, such
#         as mise.toml's or Cargo.toml's "1.95", compares major.minor. This
#         reads the rule off the value itself, so a manifest that starts
#         stating a patch is caught even if the source file does not change.
#   node: compare the major version only.
#   pnpm: compare the exact version.
#
# Sources of truth:
#   rust: flake.nix, through RUST_VERSION.
#   node: mise.toml, through MISE_NODE.
#   pnpm: package.json, through PACKAGE_PNPM.
#
# Required environment variables:
#   RUST_VERSION       flake.nix rust-overlay pin, for example 1.95.0
#   MISE_TOML_LABEL    label for mise.toml, named in failure messages
#   MISE_RUST          mise.toml [tools].rust, for example 1.95
#   MISE_NODE          mise.toml [tools].nodejs, for example 22.15.0
#   MISE_PNPM          mise.toml [tools].pnpm, for example 10.26.2
#   CARGO_TOML_LABEL   label for Cargo.toml, named in failure messages
#   CARGO_RUST         Cargo.toml [workspace.package] rust-version, for example 1.95
#   PACKAGE_JSON_LABEL label for package.json, named in failure messages
#   PACKAGE_PNPM       package.json packageManager pnpm version, for example 10.26.2
#   CI_YML_PATH        path to the ci.yml file; this script reads it
#   CI_YML_LABEL       label for that file, named in failure messages
#
# Exit code: 0 when every pin agrees. 1 when one or more pins disagree. Every
# disagreement is reported, one line per drift, before the script exits. 2
# when a required value is missing or ci.yml cannot be parsed.

set -euo pipefail

: "${RUST_VERSION:?RUST_VERSION is required}"
: "${MISE_TOML_LABEL:?MISE_TOML_LABEL is required}"
: "${MISE_RUST:?MISE_RUST is required}"
: "${MISE_NODE:?MISE_NODE is required}"
: "${MISE_PNPM:?MISE_PNPM is required}"
: "${CARGO_TOML_LABEL:?CARGO_TOML_LABEL is required}"
: "${CARGO_RUST:?CARGO_RUST is required}"
: "${PACKAGE_JSON_LABEL:?PACKAGE_JSON_LABEL is required}"
: "${PACKAGE_PNPM:?PACKAGE_PNPM is required}"
: "${CI_YML_PATH:?CI_YML_PATH is required}"
: "${CI_YML_LABEL:?CI_YML_LABEL is required}"

fail=0

field_count() {
  # Number of dot-separated fields in $1, for example 2 for "1.95".
  printf '%s' "$1" | awk -F. '{print NF}'
}

fields() {
  # The first $2 dot-separated fields of $1.
  printf '%s' "$1" | cut -d. -f1-"$2"
}

report() {
  # report <tool> <label-a> <value-a> <label-b> <value-b>
  echo "drift ($1): $2 has $3, $4 has $5"
  fail=1
}

compare_rust() {
  # compare_rust <label> <value>
  # The rule comes from the value's own precision: a two-field value such
  # as "1.95" compares major.minor, a three-field value such as "1.95.0"
  # compares major.minor.patch. Never picked by which file it came from.
  local label=$1 value=$2 n expected
  n=$(field_count "$value")
  expected=$(fields "$RUST_VERSION" "$n")
  if [ "$value" != "$expected" ]; then
    report rust "flake.nix" "$RUST_VERSION" "$label" "$value"
  fi
}

step_block() {
  # step_block <file> <step-name>
  # Print the lines of every occurrence of the named GitHub Actions step,
  # each occurrence ending at the next "- name:" line or the end of the
  # file. The step name is matched as a literal substring, not a regular
  # expression, so a name with a dot (such as "Set up Node.js") cannot
  # behave like a wildcard. Every matching occurrence is printed: a step
  # name that appears twice is not silently reduced to the first one, so a
  # second, disagreeing value still reaches the comparison below and is
  # reported as a drift.
  awk -v step="- name: $2" '
    index($0, step) { capture = 1; next }
    index($0, "- name:") { capture = 0; next }
    capture { print }
  ' "$1"
}

extract_step_field() {
  # extract_step_field <file> <step-name> <sed-extract-program> <description>
  # Runs the named step's block (every occurrence) through a `sed -nE`
  # extraction program that prints one line per match, and requires at
  # least one non-empty result. A step with no match, or a value with the
  # wrong shape, prints nothing and is treated as a parse failure, not as
  # an empty pin that would silently pass every comparison.
  local file=$1 step=$2 sed_program=$3 description=$4 value
  value=$(step_block "$file" "$step" | sed -nE "$sed_program")
  if [ -z "$value" ]; then
    echo "error: could not find $description in the '$step' step of $file" >&2
    exit 2
  fi
  printf '%s' "$value"
}

# ---- Parse the ci.yml file. ----
#
# Each extraction prints nothing, rather than an unrelated line, when the
# step does not have the expected shape (for example a
# "dtolnay/rust-toolchain@stable" with no trailing pin comment): the sed
# program only ever emits its captured group, on a match, with `-n` and a
# trailing `p`.

CI_RUST=$(extract_step_field "$CI_YML_PATH" "Set up Rust" \
  's/^.*#[[:space:]]*([0-9]+(\.[0-9]+)*)[[:space:]]*$/\1/p' \
  "the dtolnay/rust-toolchain pin comment")

CI_NODE=$(extract_step_field "$CI_YML_PATH" "Set up Node.js" \
  's/^[[:space:]]*node-version:[[:space:]]*([^[:space:]]+).*/\1/p' \
  "node-version")

CI_PNPM=$(extract_step_field "$CI_YML_PATH" "Set up pnpm" \
  's/^[[:space:]]*version:[[:space:]]*([^[:space:]]+).*/\1/p' \
  "version")

# ---- Rust: source of truth is flake.nix (RUST_VERSION). ----

compare_rust "$MISE_TOML_LABEL" "$MISE_RUST"
compare_rust "$CARGO_TOML_LABEL" "$CARGO_RUST"
compare_rust "$CI_YML_LABEL" "$CI_RUST"

# ---- Node.js: source of truth is mise.toml (MISE_NODE), major only. ----

if [ "$(fields "$CI_NODE" 1)" != "$(fields "$MISE_NODE" 1)" ]; then
  report node "$MISE_TOML_LABEL" "$MISE_NODE" "$CI_YML_LABEL" "$CI_NODE"
fi

# ---- pnpm: source of truth is package.json (PACKAGE_PNPM), exact. ----

if [ "$MISE_PNPM" != "$PACKAGE_PNPM" ]; then
  report pnpm "$PACKAGE_JSON_LABEL" "$PACKAGE_PNPM" "$MISE_TOML_LABEL" "$MISE_PNPM"
fi

if [ "$CI_PNPM" != "$PACKAGE_PNPM" ]; then
  report pnpm "$PACKAGE_JSON_LABEL" "$PACKAGE_PNPM" "$CI_YML_LABEL" "$CI_PNPM"
fi

if [ "$fail" -eq 0 ]; then
  echo "ok: rust $RUST_VERSION, node major $(fields "$MISE_NODE" 1), pnpm $PACKAGE_PNPM agree across $MISE_TOML_LABEL, $CARGO_TOML_LABEL, $CI_YML_LABEL, and $PACKAGE_JSON_LABEL"
fi

exit "$fail"
