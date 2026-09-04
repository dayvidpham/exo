# Node.js and pnpm build outputs.
#
# Returns:
#   packages.node-modules - the frozen pnpm dependency graph, installed offline
#                           from pnpm-lock.yaml
#   checks.typescript     - `pnpm check` and `pnpm format:check` against
#                           packages.node-modules
#
# See https://github.com/dayvidpham/exo/issues/3.
{ pkgs
, lib
, pname
, nodejs
, pnpm
, ...
}:

let
  # ------------------------------------------------------------------
  # Sources
  # ------------------------------------------------------------------

  # The files pnpm reads to resolve the dependency graph. Keeping this source
  # minimal means a TypeScript edit never refetches the dependency store.
  #
  # `.npmrc` and `pnpm-workspace.yaml` are both absent from the repository
  # today. They are named here anyway, through `maybeMissing`, because either
  # one changes how pnpm resolves the graph. Without them the fetch would
  # silently ignore a registry setting or a workspace setting on the day
  # somebody adds one.
  pnpmSrc = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../package.json
      ../pnpm-lock.yaml
      (lib.fileset.maybeMissing ../.npmrc)
      (lib.fileset.maybeMissing ../pnpm-workspace.yaml)
    ];
  };

  # The source `checks.typescript` reads. It is the repository minus the Rust
  # workspace and the flake itself. `oxlint`, `oxfmt`, `tsgo`, and `vitest` all
  # walk the tree from the root, so the list below is a removal list, not an
  # inclusion list: a new TypeScript directory is covered without an edit here.
  #
  # `node_modules`, `target`, and `tsconfig.tsbuildinfo` are build outputs, and
  # `.gitignore` lists all three. A flake built from a git tree drops them on
  # its own, but `nix build path:<dir>` has no git to ask, so it would copy
  # them. They are subtracted here so both ways of building agree.
  checkSrc = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.difference ../. (lib.fileset.unions [
      ../Cargo.lock
      ../Cargo.toml
      ../clippy.toml
      ../crates
      ../flake.lock
      ../flake.nix
      ../fuzz
      ../nix
      (lib.fileset.maybeMissing ../node_modules)
      (lib.fileset.maybeMissing ../target)
      (lib.fileset.maybeMissing ../tsconfig.tsbuildinfo)
    ]);
  };

  # ------------------------------------------------------------------
  # The fixed-output fetch of the pnpm store
  # ------------------------------------------------------------------

  # `pnpm-lock.yaml` holds optional dependencies that are selected by platform:
  # `@img/sharp-*`, `@typescript/native-preview-*`, `@rollup/rollup-*`,
  # `@esbuild/*`, and the per-platform `oxlint` and `oxfmt` binaries. The fetch
  # below must produce the same store on every system the flake evaluates on,
  # otherwise one declared output hash cannot serve them all. So the fetcher
  # asks pnpm for the optional dependencies of every supported platform.
  #
  # The values are npm platform, CPU, and libc names, the ones package
  # manifests use in their `os`, `cpu`, and `libc` fields. They are not Nix
  # system names. `musl` is in the list because the graph carries musl builds,
  # among them `@img/sharp-linuxmusl-x64` and the `linux-x64-musl` bindings of
  # oxlint, oxfmt, and rollup.
  #
  # The nixpkgs fetcher also passes `--force`, which on its own widens the fetch
  # to every platform. A fetch log shows win32 and android packages arriving,
  # and those are outside the set below, so this setting is not what limits the
  # fetch today. It is here to state the requirement in the flake, so the store
  # stays platform complete if the fetcher ever drops `--force`. The rule for
  # bumping the hash after a change here is at `pnpmDepsHash` below.
  supportedArchitectures = {
    os = [ "linux" "darwin" ];
    cpu = [ "x64" "arm64" ];
    libc = [ "glibc" "musl" ];
  };

  # pnpm 10 rejects `pnpm config set supportedArchitectures.os`, with
  # ERR_PNPM_CONFIG_SET_DEEP_KEY: a nested key cannot go into an `.npmrc`. pnpm
  # 10 reads nested settings from `pnpm-workspace.yaml` instead, so the fetcher
  # puts the block below into that file inside its own build directory. The
  # file never leaves the build sandbox.
  pnpmSettingsFile = (pkgs.formats.yaml { }).generate "pnpm-workspace.yaml" {
    inherit supportedArchitectures;
  };

  # The repository has no `pnpm-workspace.yaml` today. If one appears it carries
  # real settings, so merge into it rather than overwrite it. `yq` is a jq for
  # YAML: `--slurp` reads both documents into one array, `.[0] * .[1]` merges
  # them with the generated block winning, and `--yaml-output` writes YAML back.
  prePnpmInstall = ''
    if [ -f pnpm-workspace.yaml ]; then
      yq --slurp --yaml-output '.[0] * .[1]' \
        pnpm-workspace.yaml ${pnpmSettingsFile} > pnpm-workspace.merged.yaml
      mv pnpm-workspace.merged.yaml pnpm-workspace.yaml
    else
      cp ${pnpmSettingsFile} pnpm-workspace.yaml
    fi
  '';

  # Output hash of the prefetched pnpm store.
  #
  # Redo the fake hash workflow whenever `pnpm-lock.yaml` changes which packages
  # get installed, whenever the pinned pnpm version changes, and whenever
  # `supportedArchitectures` above or `fetcherVersion` below changes: set this
  # to lib.fakeHash, run `nix build .#node-modules`, and copy the reported
  # `got:` hash.
  #
  # What this hash catches, and what it does not. Measured on x86_64-linux at
  # this revision, on scratch copies of the tree.
  #
  #   A change to the resolved dependency set, a bumped version for example, is
  #   caught either way. On a warm store the fetch output path is reused,
  #   because a fixed-output derivation is addressed by its declared hash and
  #   its name and never by the lockfile, so no fetch runs and the offline
  #   install fails with `ERR_PNPM_NO_OFFLINE_TARBALL`, naming the package. When
  #   the fetch really runs, on a cold store or under
  #   `nix build .#node-modules.pnpmDeps --rebuild`, Nix compares the result
  #   against the value below and stops with `hash mismatch in fixed-output
  #   derivation`, printing `specified:` and `got:`. Copy the `got:` value here.
  #
  #   A change to an `integrity:` value alone is caught for some edits and not
  #   for others, so do not rely on it either way. Measured on one package,
  #   warm store: changing character 40 of the base64 body fails with
  #   `ERR_PNPM_NO_OFFLINE_TARBALL`, and changing the second to last data
  #   character passes with exit 0. When the fetch really runs, pnpm rejects a
  #   wrong integrity with `ERR_PNPM_TARBALL_INTEGRITY` before Nix ever compares
  #   hashes.
  #
  # So this hash guards the resolved dependency set. It is not a tamper check on
  # the bytes of `pnpm-lock.yaml`.
  #
  # Source of the value below: the fake hash workflow, on x86_64-linux.
  pnpmDepsHash = "sha256-xZdOhU/tkeZKyBnkDI/9QbIqTVzvQYKX0Y1wr075Ibs=";

  # The prefetched pnpm store, as a fixed-output derivation.
  #
  # This calls the top-level `pkgs.fetchPnpmDeps`, not `pnpm.fetchDeps`. The two
  # are not equivalent here. `pnpm.fetchDeps` in the locked nixpkgs is
  # deprecated and it hard-codes `buildPackages.pnpm_10`, which is the nixpkgs
  # pnpm, not the pnpm this flake pins to the `packageManager` version. Calling
  # the top-level fetcher with an explicit `pnpm` argument keeps the pin.
  #
  # No `version` is passed. The fetch depends on the lockfile, not on the git
  # revision, and a version in the name would give every commit a new output
  # path and refetch the whole graph.
  #
  # `fetcherVersion = 4` is the newest value the locked nixpkgs supports. Its
  # fetcher accepts 3 and 4 and rejects everything else.
  #
  # `yq` is already in the fetcher's own build inputs. It is named again here so
  # that prePnpmInstall above does not depend on that detail.
  pnpmDeps = pkgs.fetchPnpmDeps {
    inherit pname prePnpmInstall pnpm;
    src = pnpmSrc;
    fetcherVersion = 4;
    hash = pnpmDepsHash;
    nativeBuildInputs = [ pkgs.yq ];
  };

  # ------------------------------------------------------------------
  # packages.node-modules
  # ------------------------------------------------------------------

  # `pnpmConfigHook` unpacks the prefetched store and runs
  #   pnpm install --offline --ignore-scripts --frozen-lockfile
  # The fetcher above runs
  #   pnpm install --force --ignore-scripts --frozen-lockfile
  # Both pass `--ignore-scripts`, so the `prepare` script in package.json never
  # runs, so `scripts/setup-hooks.mjs` never runs, so this build never writes
  # `core.hooksPath`. That is checked by reading the two install commands in
  # nixpkgs, in pkgs/build-support/node/fetch-pnpm-deps/default.nix and
  # pnpm-config-hook.sh at the locked revision.
  #
  # The hook is taken from the top level for the same reason as the fetcher:
  # `pnpm.configHook` is deprecated and it propagates the nixpkgs pnpm, which
  # would shadow the pinned pnpm on PATH.
  #
  # Both derivations in this file use a plain `name` with no version, for the
  # reason given at the fetcher above. `mkDerivation` wants either `name` on its
  # own or `pname` together with `version`, and there is no version to give.
  node-modules = pkgs.stdenvNoCC.mkDerivation {
    name = "${pname}-node-modules";

    src = pnpmSrc;

    nativeBuildInputs = [
      nodejs
      pnpm
      pkgs.pnpmConfigHook
    ];

    inherit pnpmDeps;

    dontBuild = true;

    # `cp -a` keeps the relative symlinks that pnpm builds under
    # node_modules/.pnpm and node_modules/.bin. A copy that resolved them would
    # multiply the closure and break the `.bin` entries.
    installPhase = ''
      runHook preInstall

      mkdir -p "$out"
      cp -a node_modules "$out/node_modules"

      runHook postInstall
    '';

    meta = {
      description = "Frozen pnpm dependency graph for ${pname}";
      platforms = lib.platforms.unix;
    };
  };

  # ------------------------------------------------------------------
  # checks.typescript
  # ------------------------------------------------------------------

  # The two package.json scripts run as they are written there. `check` is
  # `pnpm lint && pnpm typecheck && pnpm test`. Running the script, not the
  # three steps, means a change to `check` is picked up here without an edit.
  typescript = pkgs.stdenvNoCC.mkDerivation {
    name = "${pname}-typescript-check";

    src = checkSrc;

    nativeBuildInputs = [
      nodejs
      pnpm
      pkgs.writableTmpDirAsHomeHook
    ];

    # pnpm 10 has manage-package-manager-versions on by default. Left on, a pnpm
    # whose version differs from `packageManager` downloads the named version
    # from the network, which cannot work in a build sandbox and would defeat
    # the pin. The pinned pnpm already matches, and this makes that independent
    # of the pin.
    npm_config_manage_package_manager_versions = "false";

    # No install step. node_modules comes from packages.node-modules, so this
    # check runs against the same tree a contributor gets from
    # `nix build .#node-modules`.
    #
    # `cp -a` keeps the file modes, which the entries under node_modules/.bin
    # need to stay runnable. Store files are read only, so the copy then takes
    # a write bit: oxlint, tsgo, and vitest all write caches inside the tree.
    configurePhase = ''
      runHook preConfigure

      cp -a ${node-modules}/node_modules node_modules
      chmod -R u+w node_modules

      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild

      echo "==> pnpm check"
      pnpm run check

      echo "==> pnpm format:check"
      pnpm run format:check

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      touch "$out"

      runHook postInstall
    '';

    meta = {
      description = "oxlint, tsgo, vitest, and oxfmt over the ${pname} sources";
      platforms = lib.platforms.unix;
    };
  };
in

{
  packages = {
    inherit node-modules;
  };

  checks = {
    inherit typescript;
  };
}
