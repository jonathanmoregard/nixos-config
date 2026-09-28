# `network-online` — shared "is this host online right now?" probe for the
# OnFailure desktop notifiers.
#
# Why it exists: every background sync on this laptop talks to GitHub, so a
# flaky Wi-Fi hour turned into a stream of CRITICAL toasts —
# 2026-09-23..28 on dellan: nixos-config-fetch 39, aggregator-ingest 31,
# ai-client-config-codex-sync 20, sota-watch 3, every one of them
# `Could not resolve host: github.com`. A toast for "you are offline" is a
# toast the operator learns to ignore, which then hides the real failures.
#
# Contract for callers (the failure notifiers): ALWAYS write the journal
# marker first, THEN ask this probe; offline → log that the toast was
# suppressed and exit 0. The unit that failed stays failed in systemd and the
# journal, so nothing is lost — only the desktop interruption is. A genuine
# fault (bad credentials, broken repo, code bug) keeps failing once the
# network is back, and the next failure is announced normally.
#
# What it measures: DNS resolution plus a TCP connect to github.com:443 —
# exactly what every gated unit needs, and what `Could not resolve host`
# says was missing. A GitHub outage also reads as "offline"; that is not a
# local fault either. Bounded by a 5s timeout so a notifier can never hang.
#
# NETWORK_ONLINE_PROBE (host:port) overrides the target; tests use it to
# drive the online branch against a local listener.
{ pkgs }:
pkgs.writeShellApplication {
  name = "network-online";
  runtimeInputs = [ pkgs.bash pkgs.coreutils ];
  text = ''
    target="''${NETWORK_ONLINE_PROBE:-github.com:443}"
    host="''${target%:*}"
    port="''${target##*:}"
    # Host and port travel as positional args, never spliced into the -c
    # string, so an odd override cannot become shell code.
    # shellcheck disable=SC2016
    exec timeout 5 bash -c ': </dev/tcp/"$1"/"$2"' network-online "$host" "$port" 2>/dev/null
  '';
}
