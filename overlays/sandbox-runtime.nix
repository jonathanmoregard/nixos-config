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

    buildPhase = ''
      runHook preBuild

      mkdir -p build
      $CC -static -O2 -Wall -Wextra \
        -o build/seccomp-unix-block \
        vendor/seccomp-src/seccomp-unix-block.c \
        -lseccomp
      build/seccomp-unix-block build/unix-block.bpf x86_64
      xxd -i -n unix_block_bpf build/unix-block.bpf \
        | sed \
            -e '1s/^unsigned char/static const unsigned char/' \
            -e '/^unsigned int unix_block_bpf_len =/d' \
        > build/unix-block-bpf.h
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
