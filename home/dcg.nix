# home/dcg.nix — dcg on PATH, its config wired to the tracked copy in
# ~/.claude, and an activation-time check that the wiring actually holds.
#
# `dcg` (overlays/dcg.nix) is the first and richest deny layer the Claude
# Code guard stack consults before running a shell command. It was
# previously `cargo install`ed into ~/.local/bin on the old Linux Mint
# box, with ~/.config/dcg/config.toml hand-symlinked to ~/.claude/dcg.toml.
# The Mint → NixOS migration dropped both. Nothing failed loudly, because
# the consumer treats "dcg missing" as "nothing to block" — so the guard
# was inert for months and the loss surfaced only when someone went
# looking. Declaring the package here makes the binary part of the system
# closure: it can no longer disappear without a diff.
#
# WHY mkOutOfStoreSymlink RATHER THAN `home.file.…text` OR `.source`
#
# The pattern list in ~/.claude/dcg.toml is edited by hand, often, while
# reasoning about a command that just got blocked. A store copy would
# freeze it: every edit would need a rebuild before it took effect, and
# an edit made without one would appear to do nothing. mkOutOfStoreSymlink
# points ~/.config/dcg/config.toml at the live file in the ~/.claude repo,
# so edits take effect on the next dcg invocation while the LINK itself
# stays declarative — the thing the migration lost was the link, not the
# file.
#
# dcg's own config-trust policy permits this: only automatically
# discovered project configs (`.dcg.toml`) and the system layer
# (/etc/dcg/config.toml) are opened O_NOFOLLOW. The user layer
# ($XDG_CONFIG_HOME/dcg/config.toml) is `ConfigSource::Untrusted`, which
# follows symlinks by design — "selecting an explicit path is itself the
# trust decision" (upstream src/config.rs).
#
# WHY THE LINK IS NOT ALLOWED TO DANGLE
#
# An earlier revision of this file shrugged a dangling link off as
# harmless — "dcg simply falls back to its built-in packs". Measured
# against v0.12.5, that fallback is the whole defect. With the target
# absent or unreadable, dcg runs to completion, exits 0, and drops the
# ENTIRE user layer:
#
#   curl -X DELETE https://example.com/x  → PERMITTED, stdout empty,
#                                           stderr EMPTY, exit 0
#   rm -rf /                              → still denied (core.filesystem)
#
# So the guard looks alive and answers correctly on the famous command
# while every destructive-HTTP rule is gone, and there is not one byte of
# diagnostic anywhere: dcg's parse-error warnings (src/config.rs:4001,
# :4016) are on the TOML-parse branch only; a read failure has no warning
# path at all. And the state is reachable in normal operation — this host
# does NOT auto-clone ~/.claude (see home/jonathan-linux.nix), so a fresh
# host boots straight into it, and claude-pull can delete the file later.
#
# The activation hooks below close that. There are two arms, and the split
# is about whether there is operator content to lose:
#
#   TARGET ABSENT  → seed ./dcg-fallback.toml at the target, announce it
#                    three ways (see "TELLING THE OPERATOR" below).
#                    Nothing is overwritten (the seed only ever runs when
#                    the path does not exist), the guard comes up ARMED
#                    rather than silently disarmed, and every deny the
#                    fallback issues names itself in its reason text.
#   TARGET STALE   → the target is still byte-for-byte the fallback an
#                    earlier activation seeded, and ./dcg-fallback.toml has
#                    changed since: refresh it in place and announce that
#                    too. Only ever overwrites this module's own bytes —
#                    see "WHY A SEEDED TARGET IS REFRESHED" below.
#   TARGET BROKEN  → fail activation, quoting dcg's own parse error.
#                    (unreadable, dangling, malformed TOML) A malformed
#                    dcg.toml today produces `Warning: Failed to parse
#                    config file …` on the STDERR OF A PRETOOLUSE HOOK,
#                    which Claude Code discards — so it reaches nobody
#                    while every override silently stops applying. We must
#                    not rewrite the operator's file to repair it, so the
#                    only honest move left is to refuse to finish.
#
# WHY "SEED" AND NOT "HARD-FAIL" ON THE ABSENT CASE
#
# Hard-failing both arms is simpler and was considered. It was rejected
# because ~/.claude is deliberately not auto-cloned: a first
# `nixos-rebuild switch` on a fresh host would then fail activation, and
# the obvious way out of a failing bootstrap is to comment this module
# out — which lands you back at "the guard is off and nobody notices",
# by a shorter road. Seeding keeps first boot working AND armed. The
# BROKEN arm cannot brick a bootstrap by construction: it requires the
# file to already exist, so it can only ever fire on a host where someone
# hand-edited it.
#
# WHY A SEEDED TARGET IS REFRESHED, AND HOW IT KNOWS IT IS ALLOWED TO
#
# The seed arm fires only on an ABSENT target, which leaves a hole exactly
# where this module is least able to afford one. Edit ./dcg-fallback.toml,
# rebuild a host that is still running the seeded copy, and:
#
#   - the seed arm does not fire, because the target exists, so the bytes
#     on disk stay the OLD fallback; and
#   - the `cmp` that decides the marker runs against the NEW store path,
#     fails, and takes the "the operator's own file is in force" branch —
#     deleting the marker and silencing the notification.
#
# The host therefore stops reporting that it is running the fallback while
# it is still running one, and not even the current one. Every channel
# under "TELLING THE OPERATOR" goes quiet at once, and it takes a routine
# edit to a tracked file to get there. That is the silent-degradation shape
# this whole module exists to make unreachable, so it cannot be left in it.
#
# What makes the refresh safe is `fallback_sha256` in the marker: it
# records the CONTENT hash of the fallback that was seeded, so a target
# that still hashes to it has not been touched since — there is provably
# nothing of the operator's to lose, and the write replaces this module's
# own bytes with this module's own bytes. A target hashing to anything else
# is theirs (their real list, or the seed with a line added), is never
# rewritten, and clears the marker exactly as before. The refusal to repair
# the operator's file is unchanged; what changed is that "the file is the
# operator's" is now a measurement rather than an assumption made from the
# path existing.
#
# The store path alone could not carry this. `fallback_source` answers
# "which file", which the edit makes unanswerable — the old path may be
# garbage-collected, and a host holding the old copy has nothing left to
# compare against. A hash does not go stale.
#
# The marker is the only provenance store, deliberately. It already means
# "the target IS the fallback"; the refresh needs "…and it is THAT
# fallback", one field further. A second state file would be a second thing
# to keep in step and a second thing to lose. Deleting the marker by hand
# therefore forfeits the refresh — the next activation cannot tell a seeded
# target from a hand-written one and so leaves it alone, which is the safe
# direction, and the marker's contract already says it is written and
# removed only here.
#
# WHY THE CHECK IS SPLIT ACROSS TWO ACTIVATION ENTRIES
#
# `dcgConfigState` seeds and records; `dcgConfigVerdict` is the only one
# that can exit 1, and it runs after EVERY other activation entry.
#
# That split is not cosmetic. Home-manager inlines all activation entries
# into a single `set -eu` bash script, and hm.dag breaks ties between
# same-dependency entries by attribute name — so the previous single
# `entryAfter [ "linkGeneration" ]` entry (`dcgConfigArmed`) sorted ahead
# of eight later steps. Measured in the GENERATED `activate` script, not
# inferred from the DAG: `dcgConfigArmed` was step 8 of 16, followed by
# `installPackages`, `dconfSettings`, `ensureClaudeLogsDir`,
# `installCalibrePlugins`, `installCrontab`, `kittyReloadConfig`,
# `onFilesChange` and `reloadSystemd`. Its `exit 1` killed all eight —
# including the crontab reinstall whose entire reason for existing is that
# skipping it leaves the live crontab silently stale (see the comment above
# `installCrontab` in home/jonathan-linux.nix), and including
# `reloadSystemd`, which is how changed user units reach systemd at all.
#
# A guard whose firing breaks unrelated machinery is a guard the operator
# learns to comment out, which converts a loud failure into a permanent
# silent one — the exact trade this module exists to refuse. So the verdict
# entry declares `entryAfter` on every other activation entry by name,
# computed from `config.home.activation` rather than hand-listed, so a
# module added later cannot quietly sort after it. Everything that can be
# applied gets applied; only the final "this generation is good" is
# withheld. The unit still fails, `nixos-rebuild switch` still reports it,
# and nixos-deploy still poisons the SHA.
#
# TELLING THE OPERATOR THAT THE FALLBACK IS IN FORCE
#
# The seeded state is the dangerous-quiet one: the host is armed, but with
# a strictly weaker rule set than the operator believes is loaded. On
# NixOS, home-manager activation runs inside `home-manager-jonathan.service`
# and `nixos-rebuild` does not stream unit logs — so a banner on stderr
# lands in `journalctl` and nowhere else, i.e. in front of nobody. Three
# channels, because each one covers the others' blind spot:
#
#   1. the stderr banner            → the record, for whoever reads the log
#   2. a desktop notification       → the human, at the moment it happens
#      (critical urgency, same channel ~/.claude/hooks/harness-tripwire.py
#      uses; best-effort — a headless or pre-login activation has no bus,
#      and that must never fail the rebuild)
#   3. a marker FILE                → the agent, at every session start
#
# Channel 3 is the durable one, and it is a cross-repo contract. Written
# and removed only here; read by the session-start guard-health hook in
# the ~/.claude repo, which this flake cannot edit.
#
#   PATH    $XDG_STATE_HOME/dcg/fallback-active.json
#           = /home/<user>/.local/state/dcg/fallback-active.json
#           (userspace state, deliberately NOT under ~/.claude — that tree
#           is Claude Code's own config/state surface and is a protected
#           path for the agent, so a marker there would be unwritable by
#           activation and unreadable-without-prompting by the hook.)
#
#   ABSENT  The dcg user layer is the operator's own file — or activation
#           has never run on this host. Both are "not the fallback".
#
#   PRESENT As of `observed_at`, the file at `target` was byte-identical
#           to `fallback_source`, i.e. the guard is running nixos-config's
#           bootstrap fallback and the operator's real pattern list is NOT
#           loaded. A reader wanting a fresher answer than `observed_at`
#           re-runs the same test: `cmp -s <target> <fallback_source>`.
#
#   FORMAT  A single JSON object, written atomically (temp + rename):
#             { "schema":          1,
#               "component":       "dcg",
#               "state":           "fallback-active",
#               "target":          "/home/<user>/.claude/dcg.toml",
#               "fallback_source": "/nix/store/…-dcg-fallback.toml",
#               "fallback_sha256": "e55b…",  # sha256 of that file, base16
#               "observed_at":     "2026-08-24T09:11:22Z",   # UTC, ISO-8601
#               "remedy":          "<one-line fix instruction>" }
#
#           `fallback_sha256` lets a reader re-run the marker's claim with
#           `sha256sum <target>` alone, without needing `fallback_source`
#           to still exist — a store path can be garbage-collected, a hash
#           cannot. Activation reads it back on the NEXT run to decide
#           whether a seeded target may be refreshed in place; see "WHY A
#           SEEDED TARGET IS REFRESHED" above.
#
#   SCHEMA  `schema` is bumped on any incompatible change. A reader that
#           does not recognise the value must treat the file as "fallback
#           possibly active" and warn — never as "unparseable, therefore
#           fine". Unreadable/garbled is the same: warn. The whole point of
#           the marker is that silence means healthy, so anything that is
#           not a confident "healthy" has to be noisy.
#
#   REFRESH Rewritten on every activation that finds the fallback in force
#           (so `observed_at` tracks reality and the notification re-fires
#           until it is fixed), and deleted on the first activation that
#           finds it is not. It is never left behind to go stale by design.
#           A fallback that CHANGED in the repo still counts as in force:
#           the target is refreshed first and the marker rewritten against
#           the new content, so the record never downgrades to "not the
#           fallback" merely because the seed moved.
#
# WHAT THIS DOES NOT COVER
#
# The window between a deletion and the next activation. Nothing on the
# host side can close that — it is a runtime property. The consumer-side
# hook is what closes it, by verifying the user layer actually loaded and
# denying when it did not (`dcg config --format json`, `.config_sources[]
# | select(.level == "user") | .status`, which is exactly what the check
# below reads).
{ config, lib, pkgs, ... }:

let
  # The out-of-store link target: the hand-edited pattern list in the
  # .claude repo. Single source for the link, the seed and the check, so
  # the three cannot drift onto different paths.
  claudeConfig = "${config.home.homeDirectory}/.claude/dcg.toml";

  # The seed, as a store path. Named once so the marker's
  # `fallback_source` field and the `install` that writes it cannot
  # disagree about which file "the fallback" means.
  fallbackSource = ./dcg-fallback.toml;

  # The seed's CONTENT, as a hash. The store path above answers "which
  # file", which stops being a useful question the moment the file is
  # edited: the path moves, and a host still holding the old copy has no
  # way to recognise it. The hash is what survives that, so it is what the
  # marker records and what the refresh arm compares against on the next
  # activation. `builtins.hashFile "sha256"` emits lowercase base16, which
  # is exactly `sha256sum`'s first field — the two are compared directly.
  fallbackSha = builtins.hashFile "sha256" fallbackSource;

  # Cross-repo contract file — see "TELLING THE OPERATOR" above for the
  # full reader contract. Literal path rather than `config.xdg.stateHome`
  # because the reader lives in another repo and needs a path it can hard-
  # code; the two agree under the XDG default.
  fallbackMarker =
    "${config.home.homeDirectory}/.local/state/dcg/fallback-active.json";

  remedy =
    "restore ~/.claude (git clone git@github.com:jonathanmoregard/.claude.git "
    + "~/.claude, or git -C ~/.claude checkout -- dcg.toml) and rebuild";

  # A dry run creates no files, so seeding would be a lie and validating
  # afterwards would report a state this run deliberately did not make.
  #
  # BOTH variables are tested. `DRY_RUN` is the live one (home-manager's
  # own CLI exports `DRY_RUN=1` and tests it with `[[ -v DRY_RUN ]]`);
  # `DRY_RUN_CMD` is derived from it and marked deprecated in home-manager's
  # generated activate script. Keying on the deprecated one ALONE — which
  # this hook used to do — means the day home-manager drops it, a
  # `dry-activate` starts seeding files and validating for real. Keying on
  # the live one alone would break in the mirror-image case. Either signal
  # is enough to skip, which is the safe direction: the failure mode of a
  # missed skip is writing a file during a dry run, while the failure mode
  # of a spurious skip is only a check deferred to the next real switch.
  notDryRun = ''[[ ! -v DRY_RUN && -z "''${DRY_RUN_CMD:-}" ]]'';
in
{
  home.packages = [ pkgs.dcg ];

  home.file.".config/dcg/config.toml".source =
    config.lib.file.mkOutOfStoreSymlink claudeConfig;

  # ── Entry 1: seed, and record whether the fallback is in force ────────
  #
  # Runs after linkGeneration so ~/.config/dcg/config.toml already exists
  # and the state this records is the real, fully-linked one. Nothing here
  # can fail the activation; that is entry 2's job and entry 2's alone.
  home.activation.dcgConfigState = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    dcgTarget="${claudeConfig}"
    dcgFallbackSource="${fallbackSource}"
    dcgFallbackSha="${fallbackSha}"
    dcgMarker="${fallbackMarker}"

    if ${notDryRun}; then

      # What a PREVIOUS activation seeded, read before anything below
      # rewrites or clears the marker. Empty when there is no marker —
      # i.e. when the target is not the fallback, or never was.
      #
      # `|| dcgSeededSha=""` on every capture: home-manager inlines these
      # entries into one `set -eu` script, so an unguarded failing command
      # substitution here would abort the WHOLE activation — which is the
      # exact collateral damage the two-entry split exists to prevent. A
      # missing or garbled marker must cost the refresh, nothing else.
      dcgSeededSha=""
      if [ -f "$dcgMarker" ]; then
        dcgSeededSha=$(${pkgs.jq}/bin/jq -r '.fallback_sha256 // empty' \
          "$dcgMarker" 2>/dev/null) || dcgSeededSha=""
      fi

      # The target's content, by the same measure. Empty for an absent
      # target, a dangling link, or one that cannot be read.
      dcgTargetSha=""
      if [ -f "$dcgTarget" ]; then
        dcgTargetSha=$(${pkgs.coreutils}/bin/sha256sum "$dcgTarget" 2>/dev/null \
          | ${pkgs.coreutils}/bin/cut -d' ' -f1) || dcgTargetSha=""
      fi

      # ── Arm 1: absent → seed, loudly ────────────────────────────────
      # -e is false for a dangling symlink, so -L is tested separately:
      # a dangling link must NOT be seeded through (install would follow
      # it and write wherever it points). It falls to arm 2 instead.
      if [ ! -e "$dcgTarget" ] && [ ! -L "$dcgTarget" ]; then
        ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$dcgTarget")"
        # Same-directory temp + rename, exactly as the marker write below.
        # `install` straight onto the live path is a WINDOW: dcg reads this
        # file on every bare-`dcg` hook invocation, i.e. once per Bash tool
        # call, and a read landing mid-write sees partial TOML. dcg treats a
        # parse error as "no user layer" and fail-opens SILENTLY on the
        # override rules — the same shape as the outage this module exists
        # to end, just narrowed to the width of one write. rename(2) is
        # atomic within a filesystem, so a concurrent reader sees either the
        # whole old file or the whole new one and never a torn one.
        ${pkgs.coreutils}/bin/install -m 0644 "$dcgFallbackSource" "$dcgTarget.tmp"
        ${pkgs.coreutils}/bin/mv -f "$dcgTarget.tmp" "$dcgTarget"
        ${pkgs.coreutils}/bin/printf '%s\n' \
          "" \
          "################################################################" \
          "#  dcg: SEEDED BOOTSTRAP FALLBACK CONFIG" \
          "#" \
          "#  $dcgTarget did not exist. home-manager just created it from" \
          "#  nixos-config home/dcg-fallback.toml." \
          "#" \
          "#  Your real dcg pattern list is NOT loaded. The fallback covers" \
          "#  destructive HTTP verbs only; everything else in your list" \
          "#  (adb, and whatever else you have added) is NOT in effect." \
          "#" \
          "#  Left alone, the link would have dangled and dcg would have" \
          "#  dropped the whole user layer silently, permitting" \
          "#  curl -X DELETE with exit 0 and no output at all." \
          "#" \
          "#  Fix: ${remedy}." \
          "################################################################" \
          "" \
          >&2

      # ── Arm 1b: still the fallback we seeded, but a DIFFERENT one ───
      #
      # The seed arm above only fires on an absent target, so without this
      # branch a host already running the seeded fallback never picks up an
      # edit to home/dcg-fallback.toml — and, worse, goes QUIET about it:
      # the `cmp` below would run against the new store path, fail, and
      # take the "operator's own file is in force" branch, deleting the
      # marker and stopping the notification while the bytes on disk stayed
      # the OLD fallback. See "WHY A SEEDED TARGET IS REFRESHED" above.
      #
      # The equality with $dcgSeededSha is the whole licence to write: the
      # target still hashes to exactly what a previous activation put
      # there, so there is nothing of the operator's to lose. Anything else
      # — their real list, or this seed with one line added — is theirs and
      # falls through untouched.
      elif [ -n "$dcgTargetSha" ] \
        && [ -n "$dcgSeededSha" ] \
        && [ "$dcgTargetSha" = "$dcgSeededSha" ] \
        && [ "$dcgTargetSha" != "$dcgFallbackSha" ]; then
        # Atomic for the same reason as the seed arm above.
        ${pkgs.coreutils}/bin/install -m 0644 "$dcgFallbackSource" "$dcgTarget.tmp"
        ${pkgs.coreutils}/bin/mv -f "$dcgTarget.tmp" "$dcgTarget"
        ${pkgs.coreutils}/bin/printf '%s\n' \
          "" \
          "################################################################" \
          "#  dcg: REFRESHED BOOTSTRAP FALLBACK CONFIG" \
          "#" \
          "#  $dcgTarget was still byte-for-byte the fallback an earlier" \
          "#  activation seeded, and nixos-config home/dcg-fallback.toml has" \
          "#  changed since. It has been updated to the current one." \
          "#" \
          "#  Nothing of yours was touched: the refresh only ever replaces" \
          "#  content this module wrote itself." \
          "#" \
          "#  Your real dcg pattern list is STILL NOT loaded. The fallback" \
          "#  covers destructive HTTP verbs only." \
          "#" \
          "#  Fix: ${remedy}." \
          "################################################################" \
          "" \
          >&2
      fi

      # ── The marker, and the desktop notification ────────────────────
      #
      # Keyed on the CURRENT state, not on whether this run did the
      # seeding: a host that was seeded three rebuilds ago is just as
      # degraded as one seeded a second ago, and the operator who has not
      # fixed it yet is exactly the one who needs telling again.
      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$dcgMarker")"
      if ${pkgs.diffutils}/bin/cmp -s "$dcgTarget" "$dcgFallbackSource"; then
        # Temp + rename, so a reader never sees a half-written object.
        ${pkgs.jq}/bin/jq -n \
          --arg target "$dcgTarget" \
          --arg fallback "$dcgFallbackSource" \
          --arg fallbackSha "$dcgFallbackSha" \
          --arg observed "$(${pkgs.coreutils}/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --arg remedy "${remedy}" \
          '{ schema: 1,
             component: "dcg",
             state: "fallback-active",
             target: $target,
             fallback_source: $fallback,
             fallback_sha256: $fallbackSha,
             observed_at: $observed,
             remedy: $remedy }' \
          > "$dcgMarker.tmp"
        ${pkgs.coreutils}/bin/mv -f "$dcgMarker.tmp" "$dcgMarker"

        # Best-effort, and deliberately so: activation must not fail
        # because nobody is logged in. `|| true` covers a missing daemon,
        # the socket test covers a pre-login activation where there is no
        # bus at all, and `timeout` covers the remaining case — a bus that
        # accepts the call and never answers. A notification channel that
        # can wedge a rebuild is worse than no notification channel.
        dcgBus="/run/user/$(${pkgs.coreutils}/bin/id -u)/bus"
        if [ -S "$dcgBus" ]; then
          DBUS_SESSION_BUS_ADDRESS="unix:path=$dcgBus" \
            ${pkgs.coreutils}/bin/timeout 5 \
            ${pkgs.libnotify}/bin/notify-send \
              --urgency=critical --app-name=dcg \
              "dcg is running the BOOTSTRAP FALLBACK" \
              "$dcgTarget is nixos-config's fallback, not your pattern list. Destructive HTTP verbs are blocked; nothing else you added is. Fix: ${remedy}." \
            || true
        fi
      else
        # Not the fallback → the operator's own file is in force. Clear
        # the marker so its presence keeps meaning something.
        ${pkgs.coreutils}/bin/rm -f "$dcgMarker" "$dcgMarker.tmp"
      fi
    fi
  '';

  # ── Entry 2: the verdict, and the only thing here that can exit 1 ─────
  #
  # `entryAfter` every other activation entry, computed rather than
  # hand-listed so a module added later cannot sort after it. hm.dag
  # tolerates names it does not know (topoSort's `before` predicate simply
  # never matches them), so this stays correct if an entry is removed.
  # `removeAttrs` on itself is what keeps it from depending on itself,
  # which hm.dag would report as a cycle.
  home.activation.dcgConfigVerdict = lib.hm.dag.entryAfter
    (lib.attrNames (removeAttrs config.home.activation [ "dcgConfigVerdict" ]))
    ''
      dcgTarget="${claudeConfig}"

      if ${notDryRun}; then
        # Ask dcg itself whether the user layer actually loaded.
        #
        # dcg's own loader is the oracle. Re-implementing a TOML parse or a
        # readlink check here would be a second implementation to drift;
        # `dcg config --format json` reports per-layer status straight out
        # of the code path the hook uses (loaded / missing / invalid /
        # rejected), with the parse error in `.detail`.
        #
        # cd / because dcg auto-discovers a project .dcg.toml from the cwd
        # and would report a layer that has nothing to do with this check.
        # env -u because DCG_CONFIG / DCG_FORMAT in the activation
        # environment would silently redirect what gets validated.
        dcgUser=$(
          cd / \
            && ${pkgs.coreutils}/bin/env -u DCG_CONFIG -u DCG_FORMAT \
                 XDG_CONFIG_HOME="$HOME/.config" \
                 ${pkgs.dcg}/bin/dcg config --format json 2>/dev/null \
            | ${pkgs.jq}/bin/jq -c '.config_sources[] | select(.level == "user")'
        ) || dcgUser=""

        dcgStatus=$(${pkgs.coreutils}/bin/printf '%s' "$dcgUser" \
          | ${pkgs.jq}/bin/jq -r '.status // "unreadable"' 2>/dev/null) || dcgStatus=""
        dcgDetail=$(${pkgs.coreutils}/bin/printf '%s' "$dcgUser" \
          | ${pkgs.jq}/bin/jq -r '.detail // "(dcg reported no detail)"' 2>/dev/null) \
          || dcgDetail="(dcg reported no detail)"

        if [ "$dcgStatus" != "loaded" ]; then
          ${pkgs.coreutils}/bin/printf '%s\n' \
            "" \
            "################################################################" \
            "#  dcg: USER CONFIG LAYER IS NOT LOADED - activation refused" \
            "#" \
            "#  ~/.config/dcg/config.toml -> $dcgTarget" \
            "#  dcg reports status: ''${dcgStatus:-<no answer from dcg config>}" \
            "#  detail: $dcgDetail" \
            "#" \
            "#  In this state dcg still runs, still exits 0, and drops your" \
            "#  ENTIRE override list. curl -X DELETE would be PERMITTED with" \
            "#  no output on stdout or stderr, while rm -rf / would still be" \
            "#  denied by a built-in pack - so the guard would look alive." \
            "#" \
            "#  Every other activation step has already run; this generation" \
            "#  is simply refusing to report success. Nothing else was" \
            "#  skipped on account of dcg." \
            "#" \
            "#  Activation is failing on purpose rather than repairing the" \
            "#  file, because the file is yours and repairing it would" \
            "#  destroy what you were editing." \
            "#" \
            "#  Fix the TOML (the parse error above names the line), then" \
            "#  rerun. Verify with: dcg config" \
            "################################################################" \
            "" \
            >&2
          exit 1
        fi
      fi
    '';
}
