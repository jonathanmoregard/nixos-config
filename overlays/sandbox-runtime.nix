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
    postInstall = (old.postInstall or "") + ''
      install -Dm755 ${applySeccomp}/bin/apply-seccomp \
        $out/lib/node_modules/@anthropic-ai/sandbox-runtime/vendor/seccomp/x64/apply-seccomp
    '';
  });
}
