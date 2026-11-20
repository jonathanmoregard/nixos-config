# nixpkgs' sandbox-runtime package omits the apply-seccomp helper, so
# allowAllUnixSockets = false silently fails open. Build the helper from the
# package's own vendored C sources and put it at the package-local path the
# runtime checks before falling back to global npm installs.
final: prev:
let
  applySeccomp = prev.pkgsStatic.stdenv.mkDerivation {
    pname = "sandbox-runtime-apply-seccomp";
    inherit (prev.sandbox-runtime) version src;

    strictDeps = true;
    nativeBuildInputs = [ prev.xxd ];
    buildInputs = [ prev.pkgsStatic.libseccomp ];

    dontConfigure = true;

    # Mirrors the package's own vendor/seccomp/build.ts. Keep the two in
    # step: apply-seccomp.c pulls its filters in as generated C arrays, so a
    # ruleset that build.ts emits and this phase does not is a compile error
    # here, not a silent downgrade. That is what srt 0.0.68 -> 0.0.81 did —
    # it split the single filter into `unix` and `namespaces`, and this phase
    # still generated only the first.
    buildPhase = ''
      runHook preBuild

      mkdir -p build
      $CC -static -O2 -Wall -Wextra \
        -o build/seccomp-unix-block \
        vendor/seccomp-src/seccomp-unix-block.c \
        -lseccomp

      # Separate arrays rather than one stacked filter, as upstream notes, so
      # a command opted out of `namespaces` still keeps `unix`.
      for rules in unix namespaces; do
        build/seccomp-unix-block "build/x86_64.$rules.bpf" x86_64 "$rules"
      done

      {
        echo '#if defined(__x86_64__)'
        xxd -i -n unix_block_bpf build/x86_64.unix.bpf \
          | sed \
              -e '1s/^unsigned char/static const unsigned char/' \
              -e '/^unsigned int unix_block_bpf_len =/d'
        xxd -i -n namespace_block_bpf build/x86_64.namespaces.bpf \
          | sed \
              -e '1s/^unsigned char/static const unsigned char/' \
              -e '/^unsigned int namespace_block_bpf_len =/d'
        echo '#else'
        echo '#error "these filters were generated for another architecture"'
        echo '#endif'
      } > build/unix-block-bpf.h

      $CC -static -O2 -Wall -Wextra \
        -I build \
        -o build/apply-seccomp \
        vendor/seccomp-src/apply-seccomp.c

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm755 build/apply-seccomp $out/bin/apply-seccomp
      runHook postInstall
    '';
  };
in
{
  sandbox-runtime = prev.sandbox-runtime.overrideAttrs (old: {
    # srt covers a protected file that does not exist yet with /dev/null bound
    # onto a regular file bubblewrap makes on the host. bubblewrap binds nodev,
    # so the device cannot be opened and nix fails every flake build in a git
    # repo without .gitmodules ("is locked: Permission denied"); and git lists
    # the mount point by its host entry type, so ~19 absent names show up as
    # untracked. The patch binds an empty read-only file instead, onto a unix
    # socket srt makes as the mount point, which git skips (measured; an empty
    # directory breaks nix's .gitmodules parser, a regular file shows in git).
    postInstall = (old.postInstall or "") + ''
      pkg=$out/lib/node_modules/@anthropic-ai/sandbox-runtime
      install -Dm755 ${applySeccomp}/bin/apply-seccomp $pkg/vendor/seccomp/x64/apply-seccomp
      install -Dm444 /dev/null $pkg/empty-placeholder
      patch -p1 -d $pkg < ${./sandbox-runtime-socket-placeholder.patch}
      substituteInPlace $pkg/dist/sandbox/linux-sandbox-utils.js \
        --replace-fail @emptyPlaceholder@ $pkg/empty-placeholder
    '';
  });
}
