# Firecracker host tooling and guest runtime for issue #7.
#
# Returns, on Linux systems only:
#   devShells.firecracker          - devShells.default plus the Firecracker host
#                                    tools from the 1.16.1 release archive
#   packages.exo-firecracker-guest - the static guest runtime built from
#                                    crates/firecracker-guest
# On every other system it returns { }.
#
# Argument set (moduleArgs from flake.nix):
#   pkgs lib self system pname version
#   rustVersion rustToolchain rustPlatform nodejs pnpm
moduleArgs@{ pkgs, lib, system, pname, ... }:

lib.optionalAttrs pkgs.stdenv.isLinux (
let
  # ------------------------------------------------------------------
  # The Firecracker host bundle
  # ------------------------------------------------------------------

  # Keep this version and the bundle table in support/firecracker/README.md in
  # step. Exo refuses to start when `firecracker` and `jailer` report different
  # versions, so both binaries must come from this one archive. The nixpkgs
  # `firecracker` package is 1.15.1 and does not match the documented bundle,
  # which is why the release archive is fetched here instead.
  firecrackerVersion = "1.16.1";

  # One release archive per architecture. Every hash below is the SHA-256 value
  # from the bundle table in support/firecracker/README.md, converted to SRI
  # with `nix hash convert --hash-algo sha256 --to sri <hex>`. Update both the
  # table and these values together.
  firecrackerArchives = {
    x86_64-linux = {
      arch = "x86_64";
      hash = "sha256-OCoCqGnk1tXLFMQFd/lUXoRYAh6osLLT/BDsFNnCQuY=";
    };
    aarch64-linux = {
      arch = "aarch64";
      hash = "sha256-jQ5p9tb5oXJFUfYH8YUEBSwWwYKO49TXtubHM4CHHg4=";
    };
  };

  firecrackerArchive =
    firecrackerArchives.${system} or (throw ''
      nix/firecracker.nix has no Firecracker release archive for the system
      "${system}". The Firecracker project publishes the 1.16.1 archive for
      x86_64 and aarch64 only, so devShells.firecracker and
      packages.exo-firecracker-guest cannot be evaluated here. Build them on
      x86_64-linux or aarch64-linux, or add the architecture and its SHA-256
      value from the bundle table in support/firecracker/README.md to
      firecrackerArchives in this file.
    '');

  # The upstream archive holds one directory, release-v<version>-<arch>, whose
  # binaries carry the version and the architecture in their file names. Exo
  # and both support scripts call `firecracker` and `jailer` by plain name, so
  # the install phase renames them.
  firecracker = pkgs.stdenvNoCC.mkDerivation {
    pname = "firecracker";
    version = firecrackerVersion;

    src = pkgs.fetchurl {
      url = "https://github.com/firecracker-microvm/firecracker/releases/download/v${firecrackerVersion}/firecracker-v${firecrackerVersion}-${firecrackerArchive.arch}.tgz";
      inherit (firecrackerArchive) hash;
    };

    sourceRoot = "release-v${firecrackerVersion}-${firecrackerArchive.arch}";

    # The archive ships prebuilt, statically linked binaries. There is nothing
    # to patch and no interpreter to rewrite.
    dontPatchELF = true;
    dontStrip = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 firecracker-v${firecrackerVersion}-${firecrackerArchive.arch} "$out/bin/firecracker"
      install -Dm755 jailer-v${firecrackerVersion}-${firecrackerArchive.arch} "$out/bin/jailer"
      runHook postInstall
    '';

    meta = {
      description = "Firecracker virtual machine monitor and its matching jailer";
      homepage = "https://github.com/firecracker-microvm/firecracker";
      license = lib.licenses.asl20;
      mainProgram = "firecracker";
      platforms = [ "x86_64-linux" "aarch64-linux" ];
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };

  # ------------------------------------------------------------------
  # The static guest runtime
  # ------------------------------------------------------------------

  # The Rust module already carries the pinned toolchain, the source fileset,
  # and the three cargoLock.outputHashes entries. Importing it with the same
  # argument set reuses all of that, so the git sources are declared in one
  # place only.
  rustModule = import ./rust.nix moduleArgs;

  # The Rust target triple this system builds for, and the cargo environment
  # variable that carries per-target flags. support/firecracker/build-guest.sh
  # uses the same pair.
  rustTarget = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  rustTargetEnvVar = "CARGO_TARGET_${pkgs.stdenv.hostPlatform.rust.cargoEnvVarTarget}_RUSTFLAGS";

  exo-firecracker-guest = rustModule.packages.exo.overrideAttrs (old: {
    pname = "exo-firecracker-guest";

    cargoBuildFlags = [ "-p" "exo-firecracker-guest" ];

    # `cargo build --target` is what keeps `+crt-static` off the host units.
    # Build scripts and procedural macros are host artifacts: rustc cannot
    # produce a procedural macro with `crt-static`, so a plain RUSTFLAGS would
    # fail the build. With an explicit target, cargo applies the per-target
    # flags below to the guest binary and its library dependencies only.
    # support/firecracker/build-guest.sh does the same thing.
    CARGO_BUILD_TARGET = rustTarget;
    ${rustTargetEnvVar} = "-C target-feature=+crt-static";

    # A fully static link needs the static glibc archives, and the order of
    # these two entries matters. This is the one full statement of the rule;
    # the packages list of devShells.firecracker below points back here.
    #
    # Every entry here becomes a `-L` in NIX_LDFLAGS, in list order, and the
    # linker takes the first match. glibc.static holds only archives, among
    # them libm.a and libpthread.a, so on its own it makes the linker resolve
    # -lm and -lpthread to archives even for a dynamic link. A build script
    # that mixes archive libm with shared libc segfaults on startup, and the
    # whole build then fails with SIGSEGV before the guest binary is reached.
    # Listing the glibc runtime output first puts the shared objects earlier in
    # the search path, so a dynamic link resolves to libm.so and a static link
    # still falls through to libm.a. Keep glibc immediately before
    # glibc.static.
    buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.glibc pkgs.glibc.static ];

    # packages.exo runs the whole workspace test suite. That work belongs to
    # packages.exo and checks.rust, and repeating it here would double the
    # build for no new information.
    doCheck = false;

    # The same rule as support/firecracker/build-guest.sh. The guest runtime is
    # PID 1 inside a microVM that has no dynamic loader, so a binary with an
    # INTERP program header cannot start. Fail the build here rather than at
    # microVM boot.
    postInstall = ''
      guest="$out/bin/exo-firecracker-guest"
      if readelf -l "$guest" | grep -q INTERP; then
        echo "nix/firecracker.nix: the guest runtime at $guest has an INTERP program header, so it is dynamically linked." >&2
        echo "The initramfs carries no dynamic loader, so this binary would fail as PID 1." >&2
        echo "Check that ${rustTargetEnvVar} still reaches the final link and that pkgs.glibc.static is in buildInputs." >&2
        exit 1
      fi
      echo "nix/firecracker.nix: verified no INTERP program header in $guest"
    '';

    meta = old.meta // {
      description = "Exo Firecracker guest runtime, statically linked, runs as PID 1";
      mainProgram = "exo-firecracker-guest";
      platforms = lib.platforms.linux;
    };
  });

  # ------------------------------------------------------------------
  # The dev shell
  # ------------------------------------------------------------------

  # devShells.default comes from the same module list flake.nix uses, so this
  # shell is the default shell plus the Firecracker host tools. It is imported
  # rather than referenced through `self`, because a module cannot read the
  # merged output set it is part of.
  devshellModule = import ./devshell.nix moduleArgs;
in
{
  packages = {
    inherit exo-firecracker-guest;
  };

  devShells.firecracker = pkgs.mkShell {
    name = "${pname}-firecracker";

    inputsFrom = [ devshellModule.devShells.default ];

    packages = [
      # firecracker and jailer, both from the 1.16.1 release archive.
      firecracker
    ]
    ++ (with pkgs; [
      # Static glibc development files, for the
      # -C target-feature=+crt-static link in
      # support/firecracker/build-guest.sh. Keep glibc immediately before
      # glibc.static: swapping them makes every dynamic link in this shell
      # produce a program that segfaults on startup. The buildInputs comment on
      # exo-firecracker-guest above explains why.
      glibc
      glibc.static

      # readelf and strip, used by support/firecracker/build-guest.sh.
      binutils

      # cpio builds the initramfs in
      # support/firecracker/build-initramfs.sh.
      cpio

      # mkfs.ext4 -d creates the guest root filesystem from a pulled OCI
      # image.
      e2fsprogs

      # Host networking for the TAP device a sandbox with networking asks
      # for.
      iproute2
      iptables
      nftables
    ]);

    # The hook only reports on host prerequisites. It never changes them.
    # /dev/kvm, cgroup v2, and IPv4 forwarding are host state, and changing any
    # of them needs root and outlives the shell.
    shellHook = ''
      exo_firecracker_warn=0

      if [ ! -e /dev/kvm ]; then
        echo "firecracker shell: /dev/kvm is missing. Firecracker needs KVM. Load the kvm_intel or kvm_amd module on this host." >&2
        exo_firecracker_warn=1
      elif [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
        echo "firecracker shell: /dev/kvm is not readable and writable by this user. Add the user to the group that owns /dev/kvm, then log in again." >&2
        exo_firecracker_warn=1
      fi

      if [ ! -e /sys/fs/cgroup/cgroup.controllers ]; then
        echo "firecracker shell: cgroup v2 is not mounted at /sys/fs/cgroup. The jailer needs the unified hierarchy. Boot this host with systemd.unified_cgroup_hierarchy=1." >&2
        exo_firecracker_warn=1
      fi

      if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" != "1" ]; then
        echo "firecracker shell: net.ipv4.ip_forward is not 1. A sandbox that asks for networking cannot reach the network. Set it with: sudo sysctl -w net.ipv4.ip_forward=1" >&2
        exo_firecracker_warn=1
      fi

      # The version is the pinned one from this file. The hook does not run the
      # virtual machine monitor to read it back: starting a VMM on every shell
      # entry costs time and prints its own exit log.
      if [ "$exo_firecracker_warn" = "0" ]; then
        echo "firecracker shell: firecracker and jailer ${firecrackerVersion}, host prerequisites present"
      else
        echo "firecracker shell: firecracker and jailer ${firecrackerVersion}, host prerequisites incomplete. See the warnings above. This shell does not change host state." >&2
      fi

      unset exo_firecracker_warn
    '';
  };
}
)
