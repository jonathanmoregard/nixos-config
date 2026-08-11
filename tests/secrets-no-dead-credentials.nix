# secrets-no-dead-credentials: eval-time guard against re-declaring a
# credential whose real home is somewhere else.
#
# The failure this prevents is not a broken build — it is two copies of one
# credential drifting apart silently. `ticktick-api-token` was declared here
# (PR #174) before anyone noticed that ~/.claude/todo/backends/ticktick.py
# already runs a TickTick OAuth client which REWRITES the access token into
# ~/.config/todo/env every time it refreshes. An agenix copy is a snapshot of
# a value that moves: the moment the backend refreshes, the two disagree and
# nothing says which is live. The consumer (the aggregator's ticktick source)
# now reads the shared store directly.
#
# Deliberately an eval check, not a VM assertion. Asserting "the file is
# absent from /run/agenix" inside the test VM would pass vacuously — the VM
# has no host key, so no secret decrypts there and every such assertion is
# green for the wrong reason. This reads the declaration itself, which is the
# thing that would actually come back.
#
# Adding an entry: only for a credential that genuinely lives elsewhere, with
# the real location named. This is not a general "secrets we removed" list.
#
# Run: nix build .#checks.x86_64-linux.secrets-no-dead-credentials -L
{ pkgs, declaredSecrets }:

let
  # name -> where the real credential lives, quoted verbatim in the failure.
  deadCredentials = {
    ticktick-api-token =
      "~/.config/todo/env (TICKTICK_ACCESS_TOKEN), rewritten on refresh by "
      + "~/.claude/todo/backends/ticktick.py; read it from there";
  };

  offenders = builtins.filter
    (name: builtins.elem name declaredSecrets)
    (builtins.attrNames deadCredentials);

  report = builtins.concatStringsSep "\n" (builtins.map
    (name: "  - ${name}: lives at ${deadCredentials.${name}}")
    offenders);
in
if offenders == [ ] then
  pkgs.runCommand "secrets-no-dead-credentials" { } ''
    echo "no dead credentials re-declared" > $out
  ''
else
  throw ''
    hosts/dellan declares age.secrets that duplicate a credential owned
    elsewhere:

    ${report}

    A second copy cannot stay in sync with a credential that is rewritten on
    refresh. Drop the declaration and read the real location, or -- if the
    ownership genuinely moved here -- remove the entry from
    tests/secrets-no-dead-credentials.nix in the same commit.
  ''
