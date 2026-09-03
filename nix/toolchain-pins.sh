#!/usr/bin/env bash
# Toolchain pin drift check.
#
# Compares the Rust, Node.js, and pnpm pins across five manifests: flake.nix,
# mise.toml, Cargo.toml, .github/workflows/ci.yml, and package.json.
#
# Nix parses flake.nix, mise.toml, Cargo.toml, and package.json before this
# script runs, with `rustVersion` (passed through moduleArgs), builtins.fromTOML,
# and builtins.fromJSON. Their already-extracted values arrive below as
# environment variables. This script parses .github/workflows/ci.yml itself,
# because Nix has no YAML parser in the standard library. The parse is
# anchored to the exact step names "Set up Rust", "Set up Node.js", and
# "Set up pnpm".
#
# Comparison rules:
#   rust: compare major.minor.patch against a manifest that states a patch
#         (.github/workflows/ci.yml). Compare major.minor against a manifest
#         that does not (mise.toml, Cargo.toml).
#   node: compare the major version only.
#   pnpm: compare the exact version.
#
# Sources of truth:
#   rust: flake.nix, through RUST_VERSION.
#   node: mise.toml, through MISE_NODE.
#   pnpm: package.json, through PACKAGE_PNPM.
#
# Required environment variables:
#   RUST_VERSION      flake.nix rust-overlay pin, for example 1.95.0
#   MISE_TOML_PATH    path to mise.toml, named in failure messages
#   MISE_RUST         mise.toml [tools].rust, for example 1.95
#   MISE_NODE         mise.toml [tools].nodejs, for example 22.15.0
#   MISE_PNPM         mise.toml [tools].pnpm, for example 10.26.2
#   CARGO_TOML_PATH   path to Cargo.toml, named in failure messages
#   CARGO_RUST        Cargo.toml [workspace.package] rust-version, for example 1.95
#   PACKAGE_JSON_PATH path to package.json, named in failure messages
#   PACKAGE_PNPM      package.json packageManager pnpm version, for example 10.26.2
#   CI_YML_PATH       path to .github/workflows/ci.yml; this script reads it
#
# Exit code: 0 when every pin agrees. 1 when one or more pins disagree. Every
# disagreement is reported, one line per drift, before the script exits. 2
# when a required value is missing or ci.yml cannot be parsed.

set -euo pipefail

: "${RUST_VERSION:?RUST_VERSION is required}"
: "${MISE_TOML_PATH:?MISE_TOML_PATH is required}"
: "${MISE_RUST:?MISE_RUST is required}"
: "${MISE_NODE:?MISE_NODE is required}"
: "${MISE_PNPM:?MISE_PNPM is required}"
: "${CARGO_TOML_PATH:?CARGO_TOML_PATH is required}"
: "${CARGO_RUST:?CARGO_RUST is required}"
: "${PACKAGE_JSON_PATH:?PACKAGE_JSON_PATH is required}"
: "${PACKAGE_PNPM:?PACKAGE_PNPM is required}"
: "${CI_YML_PATH:?CI_YML_PATH is required}"

fail=0

major_minor() {
  printf '%s' "$1" | cut -d. -f1,2
}

major() {
  printf '%s' "$1" | cut -d. -f1
}

report() {
  # report <tool> <file-a> <value-a> <file-b> <value-b>
  echo "drift ($1): $2 has $3, $4 has $5"
  fail=1
}

step_block() {
  # step_block <file> <step-name>
  # Print the lines of the named GitHub Actions step, up to but not
  # including the next "- name:" line or the end of the file. Matches on a
  # literal substring, not a regular expression, so a step name with a dot
  # (such as "Set up Node.js") cannot match the wrong line.
  awk -v step="- name: $2" '
    index($0, step) { capture = 1; next }
    capture && index($0, "- name:") { exit }
    capture { print }
  ' "$1"
}

require_nonempty() {
  # require_nonempty <value> <description>
  if [ -z "$1" ]; then
    echo "error: could not find $2 in $CI_YML_PATH" >&2
    exit 2
  fi
}

# ---- Parse .github/workflows/ci.yml. ----

ci_rust_block=$(step_block "$CI_YML_PATH" "Set up Rust")
CI_RUST=$(printf '%s\n' "$ci_rust_block" \
  | grep -E 'dtolnay/rust-toolchain' \
  | sed -E 's/^.*#[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/' \
  || true)
require_nonempty "$CI_RUST" "the dtolnay/rust-toolchain pin comment in the 'Set up Rust' step"

ci_node_block=$(step_block "$CI_YML_PATH" "Set up Node.js")
CI_NODE=$(printf '%s\n' "$ci_node_block" \
  | grep -E '^[[:space:]]*node-version:' \
  | sed -E 's/^[[:space:]]*node-version:[[:space:]]*([^[:space:]]+).*/\1/' \
  || true)
require_nonempty "$CI_NODE" "node-version in the 'Set up Node.js' step"

ci_pnpm_block=$(step_block "$CI_YML_PATH" "Set up pnpm")
CI_PNPM=$(printf '%s\n' "$ci_pnpm_block" \
  | grep -E '^[[:space:]]*version:' \
  | sed -E 's/^[[:space:]]*version:[[:space:]]*([^[:space:]]+).*/\1/' \
  || true)
require_nonempty "$CI_PNPM" "version in the 'Set up pnpm' step"

# ---- Rust: source of truth is flake.nix (RUST_VERSION). ----

if [ "$(major_minor "$MISE_RUST")" != "$(major_minor "$RUST_VERSION")" ]; then
  report rust "flake.nix" "$RUST_VERSION" "$MISE_TOML_PATH" "$MISE_RUST"
fi

if [ "$(major_minor "$CARGO_RUST")" != "$(major_minor "$RUST_VERSION")" ]; then
  report rust "flake.nix" "$RUST_VERSION" "$CARGO_TOML_PATH" "$CARGO_RUST"
fi

if [ "$CI_RUST" != "$RUST_VERSION" ]; then
  report rust "flake.nix" "$RUST_VERSION" "$CI_YML_PATH" "$CI_RUST"
fi

# ---- Node.js: source of truth is mise.toml (MISE_NODE), major only. ----

if [ "$(major "$CI_NODE")" != "$(major "$MISE_NODE")" ]; then
  report node "$MISE_TOML_PATH" "$MISE_NODE" "$CI_YML_PATH" "$CI_NODE"
fi

# ---- pnpm: source of truth is package.json (PACKAGE_PNPM), exact. ----

if [ "$MISE_PNPM" != "$PACKAGE_PNPM" ]; then
  report pnpm "$PACKAGE_JSON_PATH" "$PACKAGE_PNPM" "$MISE_TOML_PATH" "$MISE_PNPM"
fi

if [ "$CI_PNPM" != "$PACKAGE_PNPM" ]; then
  report pnpm "$PACKAGE_JSON_PATH" "$PACKAGE_PNPM" "$CI_YML_PATH" "$CI_PNPM"
fi

if [ "$fail" -eq 0 ]; then
  echo "ok: rust $RUST_VERSION, node major $(major "$MISE_NODE"), pnpm $PACKAGE_PNPM agree across mise.toml, Cargo.toml, $CI_YML_PATH, and package.json"
fi

exit "$fail"
