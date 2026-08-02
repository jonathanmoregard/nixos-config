# Aggregator GitHub ingest — systemd user timer (every 30 min).
#
# WHY this is a standalone wrapper (not a `services.aggregator.enable`
# via aggregator's own home-manager module):
#
# The aggregator repo at ~/Repos/aggregator is local-only, never pushed
# (owner directive). Adding it as a flake input (path:, git+file:) would
# fail `nix flake check` on the GitHub Actions runner which has no such
# path — flake fetchers evaluate before the check gates run. A
# `builtins.pathExists`-guarded conditional import also fails: NixOS
# pure evaluation silently reports the path as absent even on dellan,
# which would make the timer vanish from prod without CI catching it.
# SOTA guidance (research 2026-08-02): treat the aggregator as an
# opaque on-disk command, wrap it in a writeShellApplication that
# reads the agenix PAT and exports GH_TOKEN, invoke via `uv run`.
# Duplicates ~30 lines of systemd/secret glue vs. the module in
# ~/Repos/aggregator/nix/aggregator.nix; that's the price of CI safety.
#
# Consumes: age.secrets.github-readonly-pat (declared in
# hosts/dellan/default.nix with owner=jonathan / mode=0400). The PAT
# is stored raw (no `KEY=` prefix); the wrapper cats + exports it.
{ config, pkgs, lib, ... }:
let
  aggregatorRoot = "/home/jonathan/Repos/aggregator";

  ingestScript = pkgs.writeShellApplication {
    name = "aggregator-github-ingest";
    # `uv` for running the aggregator CLI in its own venv; `git` because
    # `uv run` may probe the working tree. `gh` is the CLI the ingest
    # shells out to; putting it on PATH keeps behaviour predictable.
    runtimeInputs = [ pkgs.uv pkgs.git pkgs.gh ];
    text = ''
      set -euo pipefail

      secret_path=${lib.escapeShellArg config.age.secrets.github-readonly-pat.path}
      if [ ! -r "$secret_path" ]; then
        echo "aggregator-github-ingest: secret unreadable at $secret_path (mode/owner?)" >&2
        exit 1
      fi
      # Separate assignment + export so `set -e` catches a read failure.
      # `export FOO=$(cmd)` masks cmd's exit through the export builtin.
      token=$(cat "$secret_path")
      if [ -z "$token" ]; then
        # Fail loud instead of exporting GH_TOKEN="" — an empty secret
        # usually means agenix decryption produced a zero-byte file
        # (wrong recipient, empty plaintext). Silent-degrading to
        # empty would fall through to `gh auth` (write-capable) which
        # the aggregator then refuses with WriteCapableTokenError; the
        # explicit check makes the root cause obvious in the journal.
        echo "aggregator-github-ingest: secret at $secret_path is empty" >&2
        exit 1
      fi
      export GH_TOKEN="$token"

      # Fail loudly if the checkout is missing (e.g. user renamed / moved).
      if [ ! -d ${lib.escapeShellArg aggregatorRoot} ]; then
        echo "aggregator-github-ingest: repo not found at ${aggregatorRoot}" >&2
        exit 1
      fi

      exec uv run --directory ${lib.escapeShellArg aggregatorRoot} \
        aggregator ingest github
    '';
  };
in
{
  systemd.user.services.aggregator-github-ingest = {
    description = "Aggregator: GitHub ingest (agenix-wrapped)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${ingestScript}/bin/aggregator-github-ingest";
      # Journal captures errors + row-count summary printed by the CLI.
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  systemd.user.timers.aggregator-github-ingest = {
    description = "Aggregator: GitHub ingest timer (every 30 min)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Every 30 minutes wall-clock. Matches the aggregator's own
      # nix module default (*:0/30) for consistency across timers.
      OnCalendar = "*:0/30";
      # Fire ~5 minutes after boot so a resumed laptop catches up
      # once network/VPN come back — but jitter by up to 3 min to
      # stagger against the sessions timer (if/when that gets wired
      # in a follow-up) and to avoid the tick boundary on OnCalendar
      # while other user timers fire.
      OnBootSec = "5min";
      RandomizedDelaySec = "3min";
      # Fire immediately on activation if the previous scheduled run
      # was missed (laptop closed). User timers need
      # $XDG_STATE_HOME/systemd — home-manager sets that up.
      Persistent = true;
    };
  };
}
