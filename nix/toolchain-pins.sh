#!/usr/bin/env bash
# Toolchain pin drift check.
#
# Compares the Rust, Node.js, and pnpm pins across five manifests: flake.nix,
# mise.toml, Cargo.toml, .github/workflows/ci.yml, and package.json.
#
# Nix parses flake.nix, mise.toml, Cargo.toml, and the pnpm and Node.js pins
# before this script runs, with `rustVersion`, `nodejs.version`, and
# `pnpm.version` (all passed through moduleArgs) and builtins.fromTOML.
# Their already-extracted values arrive below as environment variables. This
# script parses .github/workflows/ci.yml itself, because Nix has no YAML
# parser in the standard library. The parse is anchored to the exact step
# names "Set up Rust", "Set up Node.js", and "Set up pnpm".
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
# ci.yml can name a step twice (for example a merge conflict left both
# halves in place). A step named twice with disagreeing values is itself a
# drift: it is reported by name and never allowed to reach a normal
# comparison as a multi-line value, because a multi-line value would make a
# tool such as `cut` fail outright instead of reporting a drift.
#
# Required environment variables:
#   RUST_VERSION       flake.nix rust-overlay pin, for example 1.95.0
#   NODEJS_VERSION     flake.nix nodejs pin, for example 22.22.3
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
: "${NODEJS_VERSION:?NODEJS_VERSION is required}"
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
  # Number of dot-separated fields in $1, for example 2 for "1.95". $1 must
  # be a single value: a multi-line value must be rejected by
  # require_single before it reaches here.
  printf '%s' "$1" | awk -F. '{print NF}'
}

fields() {
  # The first $2 dot-separated fields of $1. $1 must be a single value.
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
  # $2 must be a single value; callers reading it out of ci.yml must pass
  # it through require_single first.
  local label=$1 value=$2 n expected
  n=$(field_count "$value")
  expected=$(fields "$RUST_VERSION" "$n")
  if [ "$value" != "$expected" ]; then
    report rust "flake.nix" "$RUST_VERSION" "$label" "$value"
  fi
}

require_single() {
  # require_single <tool> <step-name> <label> <values>
  # <values> may hold more than one unique line when a step name appears
  # twice in ci.yml with disagreeing values (step_block below prints every
  # occurrence, on purpose). That is itself a drift, reported here by name,
  # and this function returns 1 so the caller skips its normal comparison:
  # a multi-line value must never reach compare_rust or the other
  # comparisons, only single values may.
  local tool=$1 step=$2 label=$3 values=$4 count csv
  count=$(printf '%s\n' "$values" | wc -l)
  if [ "$count" -gt 1 ]; then
    csv=$(printf '%s\n' "$values" | paste -sd, -)
    echo "drift ($tool): $label names more than one value for the '$step' step: $csv"
    fail=1
    return 1
  fi
  return 0
}

step_block() {
  # step_block <file> <step-name>
  # Print the lines of every occurrence of the named GitHub Actions step,
  # each occurrence ending at the next "- name:" line or the end of the
  # file. The step name is matched as a literal substring, not a regular
  # expression, so a name with a dot (such as "Set up Node.js") cannot
  # behave like a wildcard. Every matching occurrence is printed: a step
  # name that appears twice is not silently reduced to the first one, so a
  # second, disagreeing value still reaches extract_step_field and
  # require_single below, and is reported as a drift rather than ignored.
  awk -v step="- name: $2" '
    index($0, step) { capture = 1; next }
    index($0, "- name:") { capture = 0; next }
    capture { print }
  ' "$1"
}

extract_step_field() {
  # extract_step_field <file> <step-name> <sed-extract-program> <description>
  # Prints the unique, non-empty matches found across every occurrence of
  # the named step (one per line). Requires at least one match; a step with
  # no match, or a value with the wrong shape, prints nothing and is a
  # parse failure (exit 2), not an empty pin that would silently pass every
  # comparison. More than one unique match is not an error here: the
  # caller runs the result through require_single, because only the caller
  # knows which tool and comparison are involved.
  local file=$1 step=$2 sed_program=$3 description=$4 values
  values=$(step_block "$file" "$step" | sed -nE "$sed_program" | sort -u)
  if [ -z "$values" ]; then
    echo "error: could not find $description in the '$step' step of $file" >&2
    exit 2
  fi
  printf '%s\n' "$values"
}

# ---- Parse the ci.yml file. ----
#
# Each extraction prints nothing, rather than an unrelated line, when the
# step does not have the expected shape (for example a
# "dtolnay/rust-toolchain@stable" with no trailing pin comment): the sed
# program only ever emits its captured group, on a match, with `-n` and a
# trailing `p`. The rust program is anchored to the "uses:" line itself, so
# a later comment elsewhere in the same step (for example "# MSRV 1.90" on
# an unrelated line) is never read as the pin.

CI_RUST=$(extract_step_field "$CI_YML_PATH" "Set up Rust" \
  's/^[[:space:]]*uses:.*#[[:space:]]*([0-9]+(\.[0-9]+)*)[[:space:]]*$/\1/p' \
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
if require_single rust "Set up Rust" "$CI_YML_LABEL" "$CI_RUST"; then
  compare_rust "$CI_YML_LABEL" "$CI_RUST"
fi

# ---- Node.js: source of truth is mise.toml (MISE_NODE), major only. The
# ---- flake's own Node.js (NODEJS_VERSION) must agree with it too. ----

if [ "$(fields "$NODEJS_VERSION" 1)" != "$(fields "$MISE_NODE" 1)" ]; then
  report node "flake.nix" "$NODEJS_VERSION" "$MISE_TOML_LABEL" "$MISE_NODE"
fi

if require_single node "Set up Node.js" "$CI_YML_LABEL" "$CI_NODE"; then
  if [ "$(fields "$CI_NODE" 1)" != "$(fields "$MISE_NODE" 1)" ]; then
    report node "$MISE_TOML_LABEL" "$MISE_NODE" "$CI_YML_LABEL" "$CI_NODE"
  fi
fi

# ---- pnpm: source of truth is package.json (PACKAGE_PNPM), exact. ----

if [ "$MISE_PNPM" != "$PACKAGE_PNPM" ]; then
  report pnpm "$PACKAGE_JSON_LABEL" "$PACKAGE_PNPM" "$MISE_TOML_LABEL" "$MISE_PNPM"
fi

if require_single pnpm "Set up pnpm" "$CI_YML_LABEL" "$CI_PNPM"; then
  if [ "$CI_PNPM" != "$PACKAGE_PNPM" ]; then
    report pnpm "$PACKAGE_JSON_LABEL" "$PACKAGE_PNPM" "$CI_YML_LABEL" "$CI_PNPM"
  fi
fi

if [ "$fail" -eq 0 ]; then
  echo "ok: rust $RUST_VERSION, node major $(fields "$MISE_NODE" 1) (flake.nix $NODEJS_VERSION), pnpm $PACKAGE_PNPM agree across $MISE_TOML_LABEL, $CARGO_TOML_LABEL, $CI_YML_LABEL, and $PACKAGE_JSON_LABEL"
fi

exit "$fail"
