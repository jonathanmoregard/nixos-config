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
# The activation hook below closes that. It has two arms, and the split
# is about whether there is operator content to lose:
#
#   TARGET ABSENT  → seed ./dcg-fallback.toml at the target and print an
#                    unmissable banner. Nothing is overwritten (the seed
#                    only ever runs when the path does not exist), the
#                    guard comes up ARMED rather than silently disarmed,
#                    and every deny the fallback issues names itself in
#                    its reason text.
#   TARGET BROKEN  → hard-fail activation, quoting dcg's own parse error.
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
in
{
  home.packages = [ pkgs.dcg ];

  home.file.".config/dcg/config.toml".source =
    config.lib.file.mkOutOfStoreSymlink claudeConfig;

  # Runs after linkGeneration so ~/.config/dcg/config.toml already exists
  # and `dcg config` sees the real, fully-linked state — and as late as
  # possible, so the hard-fail arm aborts after the rest of the
  # generation has already been applied.
  home.activation.dcgConfigArmed = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    dcgTarget="${claudeConfig}"

    # A dry run creates no files, so seeding is skipped and validating
    # afterwards would report a state this run deliberately did not make.
    if [ -z "''${DRY_RUN_CMD:-}" ]; then

      # ── Arm 1: absent → seed, loudly ────────────────────────────────
      # -e is false for a dangling symlink, so -L is tested separately:
      # a dangling link must NOT be seeded through (install would follow
      # it and write wherever it points). It falls to arm 2 instead.
      if [ ! -e "$dcgTarget" ] && [ ! -L "$dcgTarget" ]; then
        ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$dcgTarget")"
        ${pkgs.coreutils}/bin/install -m 0644 ${./dcg-fallback.toml} "$dcgTarget"
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
          "#  Fix: restore ~/.claude (clone the .claude repo, or" \
          "#  git -C ~/.claude checkout -- dcg.toml) and rebuild." \
          "################################################################" \
          "" \
          >&2
      fi

      # ── Arm 2: ask dcg itself whether the user layer actually loaded ─
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
