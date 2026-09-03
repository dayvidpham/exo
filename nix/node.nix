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
, version
, nodejs
, pnpm
, ...
}:

let
  # ------------------------------------------------------------------
  # Sources
  # ------------------------------------------------------------------

  # The only files pnpm reads to resolve the dependency graph. Keeping this
  # source minimal means a TypeScript edit never refetches the dependency
  # store. The repository has no pnpm workspace file and no `.npmrc`, so these
  # two files are the whole input.
  pnpmSrc = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../package.json
      ../pnpm-lock.yaml
    ];
  };

  # The source `checks.typescript` reads. It is the repository minus the Rust
  # workspace and the flake itself. `oxlint`, `oxfmt`, `tsgo`, and `vitest` all
  # walk the tree from the root, so the list below is a removal list, not an
  # inclusion list: a new TypeScript directory is covered without an edit here.
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
  # The values are npm platform and CPU names, the ones package manifests use
  # in their `os` and `cpu` fields. They are not Nix system names.
  #
  # The nixpkgs fetcher also passes `--force`, which on its own widens the fetch
  # to every platform. A fetch log shows win32 and android packages arriving,
  # and those are outside the set below, so this setting is not what limits the
  # fetch today. It is here to state the requirement in the flake, so the store
  # stays platform complete if the fetcher ever drops `--force`. Treat a change
  # to this set as a reason to redo the fake hash workflow.
  supportedArchitectures = {
    os = [ "linux" "darwin" ];
    cpu = [ "x64" "arm64" ];
  };

  # pnpm 10 rejects `pnpm config set supportedArchitectures.os`, with
  # ERR_PNPM_CONFIG_SET_DEEP_KEY: a nested key cannot go into an `.npmrc`. pnpm
  # 10 reads nested settings from `pnpm-workspace.yaml` instead, so the fetcher
  # writes that file into its own build directory. The repository has no such
  # file, and this one never leaves the build sandbox.
  pnpmSettingsFile = (pkgs.formats.yaml { }).generate "pnpm-workspace.yaml" {
    inherit supportedArchitectures;
  };

  prePnpmInstall = ''
    cp ${pnpmSettingsFile} pnpm-workspace.yaml
  '';

  # Output hash of the prefetched pnpm store.
  # Bump this hash whenever `pnpm-lock.yaml` changes, whenever the pinned pnpm
  # version changes, and whenever `supportedArchitectures` or `fetcherVersion`
  # above changes: set it to lib.fakeHash, run `nix build .#node-modules`, and
  # copy the reported `got:` hash.
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
  # `fetcherVersion = 4` is the newest value the locked nixpkgs supports. Its
  # fetcher accepts 3 and 4 and rejects everything else.
  pnpmDeps = pkgs.fetchPnpmDeps {
    inherit pname version prePnpmInstall pnpm;
    src = pnpmSrc;
    fetcherVersion = 4;
    hash = pnpmDepsHash;
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
  node-modules = pkgs.stdenvNoCC.mkDerivation {
    pname = "${pname}-node-modules";
    inherit version;

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

  # `pnpm check` is `pnpm lint && pnpm typecheck && pnpm test`. The three run
  # one after another below, so a failure names the step that failed.
  typescript = pkgs.stdenvNoCC.mkDerivation {
    name = "${pname}-typescript-check-${version}";

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

      echo "==> pnpm lint"
      pnpm run lint

      echo "==> pnpm typecheck"
      pnpm run typecheck

      echo "==> pnpm test"
      pnpm run test

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
