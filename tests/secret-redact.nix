# Not a VM lane: drives the built `secret-redact` — its pinned gitleaks and
# rules — inside the build sandbox. One check per gitleaks quirk the CLI
# handles, every fail-closed exit, and the redaction contract its callers
# (~/.claude output hooks, aggregator ingest) rely on. See
# tests/secret-redact.py for the cases.
#
# Run: nix build .#checks.x86_64-linux.secret-redact -L
{ pkgs }:
pkgs.runCommand "secret-redact-check" {
  nativeBuildInputs = [ pkgs.python3 pkgs.bash ];
} ''
  export HOME=$TMPDIR
  python3 ${./secret-redact.py} ${pkgs.secret-redact}/bin/secret-redact ${pkgs.bash}/bin/sh
  touch $out
''
