# The VSCodium settings drift recorder + reporter, as one binary.
#
# Its own file, imported by both home/vscodium.nix (which runs `record` from
# the activation entry) and home/drift-analyzer.nix (which runs `report` from
# the hourly probe), for the reason home/vscodium.nix already gives about
# claude-egress-launch: a second copy would drift toward "looks observed,
# isn't". Here that risk is concrete — the recorder and the reporter must
# agree about what counts as drift, or the hourly report calls a key clean
# that the merge discarded an hour earlier.
#
# `python3 -I` is isolated mode: no PYTHONPATH, no cwd on sys.path, no user
# site-packages. json5 therefore has to come from the interpreter's own
# closure, which is what withPackages builds, and a stray json5.py beside the
# script cannot shadow it.
{ pkgs }:
let
  python = pkgs.python3.withPackages (ps: [ ps.json5 ]);
in
pkgs.writeShellApplication {
  name = "vscodium-drift-tool";
  runtimeInputs = [ python ];
  text = ''
    exec ${python}/bin/python3 -I ${./vscodium-drift-tool.py} "$@"
  '';
}
