# Aggregator ingest — ONE systemd user timer that walks all nine sources.
#
# Replaces the github-only timer (modules/nixos/aggregator-github-timer.nix,
# unit `aggregator-github-ingest`). The aggregator grew a unified import
# runner: `aggregator ingest --all` drives sessions, github, chatgpt,
# claude-web, research, sota-watch, substack, dropbox and ticktick through
# one pass with per-source failure isolation — one source raising costs its
# own line in the run report and nothing else. One timer, one report, one
# notify wiring, instead of nine of each.
#
# ── What this unit runs: a store path, and ONLY a store path ──
#
# Until 2026-08-16 the wrapper's last line was
#
#     exec uv run --directory /home/jonathan/Repos/aggregator aggregator ingest --all
#
# so ExecStart's store path was a decoy: the code that actually ran was
# whatever happened to be checked out in the developer's tree at the moment
# the timer fired — any branch, any uncommitted edit. `uv run` also WRITES
# to that tree (venv resolve/sync, potentially uv.lock) from an unattended
# systemd unit. There was no deployed artifact at all; "merged to main" and
# "what runs" were unrelated facts.
#
# It now execs `${pkgs.aggregator}/bin/aggregator`, built by
# overlays/aggregator.nix (uv2nix) from the rev pinned in flake.lock. Read
# that file for the packaging rationale, the spaCy/Presidio note, and the
# bump procedure. Nothing below may name a path under /home/ for the code
# it runs — tests/base.nix asserts that mechanically, because a config
# change with no test regresses silently and that is exactly how the `uv
# run` line survived four PRs.
#
# The unit still does NOT use `services.aggregator.enable` from the
# aggregator's own home-manager module: that module predates the unified
# `ingest --all` runner and still wires one unit per source, which is what
# this timer deliberately replaced.
#
# Consumes: age.secrets.github-readonly-pat (declared in
# hosts/dellan/default.nix with owner=jonathan / mode=0400). The PAT is
# stored raw (no `KEY=` prefix); the wrapper cats + exports it. github is one
# of the nine sources and still needs GH_TOKEN, so the agenix wrapper stays
# exactly as it was.
#
# NO agenix secret for ticktick, deliberately. The ticktick source reads
# TICKTICK_ACCESS_TOKEN from the shared ~/.config/todo/env store, which
# ~/.claude/todo/backends/ticktick.py rewrites on every OAuth refresh. PR
# #177 removed the duplicate declaration and
# `checks.x86_64-linux.secrets-no-dead-credentials` fails the build if it
# comes back. Nothing here declares one.
#
# ── Failure reporting: TWO channels, deliberately, covering disjoint holes ──
#
#   1. `OnFailure=aggregator-ingest-failure-notify.service` (systemd).
#      Fires when the UNIT fails — i.e. the wrapper died before or instead
#      of producing a run report: unreadable/empty agenix secret, missing
#      checkout, `uv` broken, TimeoutStartSec reaped a wedged run, OOM kill.
#      In every one of those cases the aggregator's in-process notifier
#      never got to run, so without this channel the failure reaches the
#      journal and nowhere else. Same shape as the sota-watch OnFailure
#      chain (home/sota-watch.nix) — which is itself the user-manager
#      instance of the nixos-deploy.service notify pattern
#      (modules/nixos/nixos-auto-deploy.nix): `notify-send -u critical`,
#      journal marker first. nixos-deploy needs a root->user flag-file hop
#      via a path unit because it runs on the SYSTEM manager; this unit
#      already runs on jonathan's user manager, so `OnFailure=` reaches the
#      session bus directly and the hop is unnecessary.
#
#   2. `AGGREGATOR_NOTIFY_COMMAND` (in-process, the aggregator's own
#      notifier). Fires on a run that SUCCEEDS at the systemd level but has
#      something to say: a hand-refreshed export archive has gone stale (the
#      chat exports, the TickTick CSV). Such a run exits 0 with every count
#      at 0 and is otherwise indistinguishable from a healthy no-op —
#      OnFailure can never see it. Presence of the variable is what installs
#      the notifier, so no argv change is needed; its value names the
#      program, shlex-split and argv-exec'd, never a shell.
#
#   Overlap is intentional and cheap: a run that ends with a non-empty
#   errors list exits 3, so BOTH channels fire (one CRITICAL toast from the
#   CLI naming the failing sources, one from OnFailure naming the unit).
#   Two toasts for one incident beats dropping either channel, each of which
#   is the only cover for its own class.
#
#   The value is an ABSOLUTE store path on purpose. The aggregator resolves
#   it with shutil.which() on every run and turns an unresolvable program
#   into a run error (exit 3), so a bare `notify-send` would depend on the
#   user manager's PATH. Note also that `Environment=AGGREGATOR_NOTIFY_COMMAND=`
#   — the empty spelling — is the one shape the aggregator treats as a loud
#   config error rather than "off"; the VM test asserts the value is
#   non-empty and executable so that footgun cannot land silently.
#
# ── Cadence: still every 30 minutes ──
#
# Kept at `*:0/30` even though the unit now walks nine sources rather than
# one:
#
#   * The freshness that matters is `sessions`. ~/.claude/projects is
#     appended to continuously and is what `aggregator_search_memory`
#     answers "what did we decide an hour ago" from. Halving the poll rate
#     halves recall freshness for the only source that changes
#     minute-to-minute; the other eight change daily at best.
#   * Seven of the nine read local directories. On a tick with nothing new
#     they cost a directory walk and zero writes — the upsert path is
#     idempotent per stable id.
#   * Network budget is unchanged in shape. github still makes the same `gh`
#     calls it made at this cadence before; ticktick adds one bounded HTTPS
#     poll per tick. 48 runs/day is nowhere near either API's limits, and
#     every network call in the source layer carries its own timeout.
#   * Ticks cannot pile up. systemd will not re-trigger a timer whose unit
#     is still active — a long run costs a skipped tick, not a second
#     concurrent writer against cache.db.
#
# Rejected: hourly (costs the sessions freshness that motivates the whole
# index, and does not fix anything else); per-source timers (that is exactly
# what `--all` replaced).
#
# KNOWN, ACCEPTED NAG: staleness is recomputed per run and not deduplicated,
# so while an export archive is past --stale-after-days (default 14) the
# in-process notifier emits one normal-urgency toast per tick. If that gets
# annoying before the export ritual is automated, the fix belongs in the
# aggregator (a delivered-receipt barrier for staleness warnings), not here.
#
# ── TLS trust store: why this unit must name a CA bundle explicitly ──
#
# A systemd unit starts from a near-empty environment — none of the login
# shell's exports reach it. Without SSL_CERT_FILE, OpenSSL falls back to the
# paths its build baked in, and for the interpreter this unit actually runs
# those paths are wrong on NixOS:
#
#   `uv run` did not use the system python. It fetched a python-build-
#   standalone CPython whose OpenSSL was compiled with
#   cafile=/etc/ssl/cert.pem (absent on NixOS) and capath=/etc/ssl/certs
#   (present, but two symlinks — not an OpenSSL hashed CA directory). Both
#   lookups miss, so the default SSLContext holds ZERO CAs:
#
#     $ env -u SSL_CERT_FILE uv run --directory ~/Repos/aggregator python -c \
#         'import ssl; print(ssl.create_default_context().cert_store_stats())'
#     {'x509': 0, 'crl': 0, 'x509_ca': 0}
#     $ ... cafile="/etc/ssl/certs/ca-bundle.crt" ...
#     {'x509': 172, 'crl': 0, 'x509_ca': 172}
#
# Observed 2026-08-15 21:59:01 as `ticktick api poll failed: URLError:
# <urlopen error [SSL: CERTIFICATE_VERIFY_FAILED] ... self-signed certificate
# in certificate chain>`. Not a MITM and not an aggregator bug: with zero
# trusted roots every chain is self-signed as far as OpenSSL is concerned.
# ticktick was merely the first source to notice — it is the only one that
# speaks HTTPS from python's stdlib (github shells out to `gh`, which carries
# its own nixpkgs-wrapped trust store, and the other seven read local
# directories). EVERY future HTTPS source would have hit the same wall.
#
# /etc/ssl/certs/ca-bundle.crt, not ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt:
# the /etc path is what home/research-agent-mcp.nix, home/futuresearch-gate-
# mcp.nix and home/claude-services.nix already use, it is generated by
# `security.pki` from pkgs.cacert PLUS anything the host adds via
# `security.pki.certificateFiles` (a store path silently drops those), and it
# does not pin the trust store to the closure this module happened to be
# evaluated against.
#
# Kept after the move to a store-path build even though the interpreter
# changed. The packaged venv runs nixpkgs' python311, which IS compiled
# against /etc/ssl/certs/ca-certificates.crt, so the zero-CA fallback above
# is no longer reachable through that particular door — but SSL_CERT_FILE
# is read by OpenSSL itself, NIX_SSL_CERT_FILE by every nixpkgs cacert
# wrapper on this unit's PATH (`gh` among them), and a unit that names its
# trust store explicitly cannot inherit a broken one. Removing two
# Environment= lines to save nothing is how the 2026-08-15 incident would
# come back through a different interpreter.
{ config, pkgs, lib, ... }:
let
  # The deployed artifact. Store path, pinned rev, no working tree.
  aggregatorBin = lib.getExe pkgs.aggregator;

  # Absolute path — see the AGGREGATOR_NOTIFY_COMMAND note in the header.
  notifyCommand = "${pkgs.libnotify}/bin/notify-send";

  # See the TLS trust store note in the header. Symlink into
  # /etc/static/ssl/certs, maintained by security.pki.
  caBundle = "/etc/ssl/certs/ca-bundle.crt";

  # Activated only via OnFailure. Emits the journal marker FIRST and treats
  # the desktop toast as best-effort: a headless boot or a session with no
  # notification daemon must not turn the notifier itself red (which would
  # then be a second failed unit reporting nothing), but the fallback is
  # logged so it stays diagnosable. The marker is also what the VM test
  # asserts on — it works without a notification daemon.
  failureNotifyScript = pkgs.writeShellScript "aggregator-ingest-failure-notify" ''
    set -uo pipefail

    echo "aggregator ingest run FAILED — inspect: journalctl --user -u aggregator-ingest.service -n 200"
    if ! ${notifyCommand} -u critical -a aggregator \
      "aggregator ingest FAILED" \
      "The all-sources ingest run exited non-zero. Likely: unreadable/empty github-readonly-pat, no usable CA bundle, or a run that ended with errors (exit 3). Details: journalctl --user -u aggregator-ingest.service -n 200"; then
      echo "notify-send failed (no notification daemon on session bus?) — failure recorded in journal only"
    fi
  '';

  ingestScript = pkgs.writeShellApplication {
    name = "aggregator-ingest";
    # `gh` is the only external command the aggregator shells out to
    # (aggregator/sources/github.py). `coreutils` so `cat` does not depend
    # on whatever PATH the user manager happened to inherit. `libnotify` so
    # a future edit that spells the notify command bare still resolves it.
    #
    # `uv` and `git` are deliberately GONE. They were here to run the CLI
    # out of the developer's checkout; keeping them on PATH would leave the
    # tools that made the old failure mode possible one typo away.
    runtimeInputs = [ pkgs.gh pkgs.coreutils pkgs.libnotify ];
    text = ''
      set -euo pipefail

      secret_path=${lib.escapeShellArg config.age.secrets.github-readonly-pat.path}
      if [ ! -r "$secret_path" ]; then
        echo "aggregator-ingest: secret unreadable at $secret_path (mode/owner?)" >&2
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
        echo "aggregator-ingest: secret at $secret_path is empty" >&2
        exit 1
      fi
      export GH_TOKEN="$token"

      # No checkout guard any more, and that absence is the point: the code
      # is a store path in this unit's own closure, so it cannot be missing
      # while the unit exists. The guard it replaces ("repo not found at
      # ...") only ever protected against the working-tree dependency this
      # change removed. NOTE: nothing in this script may spell a path under
      # the home directory, not even in a comment — tests/base.nix greps
      # the generated text, deliberately without parsing shell syntax.

      # CA bundle guard. The unit sets SSL_CERT_FILE (see the TLS note in
      # the header); this asserts the value still resolves to a non-empty
      # file before any source opens a socket. Deliberately loud rather
      # than best-effort: a missing bundle degrades to zero trusted roots,
      # and zero trusted roots does not look like a config error in the
      # journal — it looks like every HTTPS host on the internet suddenly
      # serving a self-signed certificate, which is exactly the wrong
      # investigation to send a human on. `:-` so a hand-run of this script
      # outside systemd reports the same diagnosis instead of tripping
      # `set -u` with an unbound-variable trace.
      ca_bundle="''${SSL_CERT_FILE:-}"
      if [ -z "$ca_bundle" ] || [ ! -s "$ca_bundle" ]; then
        echo "aggregator-ingest: no usable CA bundle (SSL_CERT_FILE='$ca_bundle') — every HTTPS source would fail CERTIFICATE_VERIFY_FAILED against an empty trust store" >&2
        exit 1
      fi

      # `exec`, so the CLI's exit status IS the unit's exit status with no
      # wrapper in between. That matters for the aggregator's exit-code
      # contract: 0 clean, 2 usage error, 3 completed with errors (a
      # PARTIALLY successful run still exits 3, deliberately). 3 must reach
      # systemd unaltered so the unit fails and OnFailure fires. Capturing
      # the status by hand to log a friendlier line is exactly the shape
      # that produced the PR #67 incident (`if ! cmd; then rc=$?` — bash
      # zeroes rc), so we do not; the CLI already prints its own error
      # lines to the journal ahead of exiting.
      #
      # No --notify: AGGREGATOR_NOTIFY_COMMAND in the unit environment
      # installs the notifier on its own. No --stale-after-days: the
      # aggregator's default of 14 days is half an export-refresh cycle,
      # which is the intended cadence here.
      exec ${lib.escapeShellArg aggregatorBin} ingest --all
    '';
  };
in
{
  systemd.user.services.aggregator-ingest = {
    description = "Aggregator: all-sources ingest (agenix-wrapped)";
    unitConfig.OnFailure = "aggregator-ingest-failure-notify.service";
    environment = {
      # Presence installs the aggregator's in-process notifier; the value
      # names the program. See the two-channel note in the header.
      AGGREGATOR_NOTIFY_COMMAND = notifyCommand;

      # TLS trust store. See the header note for the zero-CA incident this
      # closes. Set on the UNIT rather than exported inside the wrapper so it
      # covers the whole process tree — uv's own downloader, git, gh, and the
      # aggregator's python — and so `systemctl --user show -p Environment`
      # is the single place an operator (and tests/base.nix) can read it.
      #
      # Both spellings, deliberately, because two different consumers read
      # two different names: SSL_CERT_FILE is OpenSSL's own override (this is
      # the one python's `ssl`, and therefore the ticktick source's urllib,
      # honours), while NIX_SSL_CERT_FILE is what nixpkgs' cacert setup-hook
      # wrappers read (curl, git and the nix client among them). Setting only
      # one leaves the other half of the tree on its broken compiled default.
      SSL_CERT_FILE = caBundle;
      NIX_SSL_CERT_FILE = caBundle;
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${ingestScript}/bin/aggregator-ingest";
      # Type=oneshot disables TimeoutStartSec by DEFAULT (systemd.service(5)),
      # so without this line a wedged run can hold the unit "activating"
      # forever and every later tick silently no-ops — the exact shape of
      # the 2026-06-14 nixos-deploy incident (17h activating, merged PRs
      # never reaching the host). 4h is chosen ABOVE the measured cold
      # first-run cost of the sessions source (~3.1h against a real
      # ~/.claude/projects tree, 5678 sessions / 348168 observations,
      # measured 2026-08-02) so a legitimate cold scan is never reaped into
      # a loop that can never converge; steady-state incremental runs are
      # orders of magnitude under it. On expiry systemd fails the unit,
      # which routes into OnFailure and tells a human — the point is that a
      # wedge is BOUNDED and LOUD, not that it is fast.
      TimeoutStartSec = "4h";
      # Journal captures errors + the per-source run report printed by the
      # CLI. This is where an operator reads what happened after the fact.
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  # Activated only via OnFailure — no wantedBy on purpose.
  systemd.user.services.aggregator-ingest-failure-notify = {
    description = "Desktop notification: aggregator ingest run failed";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${failureNotifyScript}";
    };
  };

  systemd.user.timers.aggregator-ingest = {
    description = "Aggregator: all-sources ingest timer (every 30 min)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Every 30 minutes wall-clock — see the cadence section in the header
      # for why nine sources did not change this.
      OnCalendar = "*:0/30";
      # Fire ~5 minutes after boot so a resumed laptop catches up once
      # network/VPN come back, jittered by up to 3 min so the run does not
      # land exactly on the tick boundary shared with every other user
      # timer on this host.
      OnBootSec = "5min";
      RandomizedDelaySec = "3min";
      # Fire immediately on activation if the previous scheduled run was
      # missed (laptop closed). User timers need $XDG_STATE_HOME/systemd —
      # home-manager sets that up.
      Persistent = true;
    };
  };
}
