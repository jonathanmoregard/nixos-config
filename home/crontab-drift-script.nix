{ pkgs }:

# crontab-drift-check — detect divergence between the LIVE user crontab
# and the crontab rendered by home/jonathan-linux.nix, and open a PULL
# REQUEST adding the stray entries to that file.
#
# WHY THIS EXISTS. `home.file.".config/crontab"` is the declaration and
# `home.activation.installCrontab` rewrites the live crontab from it on
# every `nixos-rebuild switch`. Anything installed with `crontab -e` or
# `crontab -` therefore survives only until the next rebuild. That has
# eaten scheduled work three times, once for four months without anyone
# noticing (the RSI daily reviewer, dead 2026-04-17 → 2026-08-01).
#
# THE DECLARATION IS TRUTH. This never commits to main and never writes
# the live state into the config silently: it opens a PR a human
# approves. Silently adopting live state would launder undeclared drift
# into config — anything a plugin installer scribbles into the crontab
# would become permanent config with nobody checking it. Rejecting a
# proposed entry is "close the PR and `crontab -r` it away", not "merge
# and hope".
#
# LOUD ON ITS OWN FAILURE. The failure this unit guards against went
# unnoticed for four months, so a checker that fails quietly is worse
# than no checker. Every path that cannot do the job exits non-zero;
# the unit's OnFailure notifier turns that into a critical desktop
# notification (home/drift-analyzer.nix). Findings that are not checker
# failures (declared-but-not-live, unclassifiable live-only lines) get
# their own critical notify-send and keep the unit green, deduplicated
# by content hash so the alarm does not become background noise.
#
# TWO DRIFT DIRECTIONS, TWO RESPONSES:
#   live-only schedule entry  → PR candidate (this is the main path)
#   declared-but-not-live     → activation failed or something clobbered
#                               the live crontab; there is nothing to add
#                               to the declaration, so notify + journal
#   live-only NON-entry       → env assignments (PATH=, CRON_TZ=) and
#     (unclassified)            anything that is not a schedule line are
#                               never auto-filed. A stale `PATH=` left
#                               live by a skipped activation would
#                               otherwise be proposed as a SECOND PATH=
#                               line in the declaration — silently
#                               changing the environment of every job.
#
# IDEMPOTENCE. The branch name carries a sha256 of the sorted stray
# entries: `crontab-drift/<12 hex>`. Before doing anything the script
# asks origin whether that branch exists; if it does, the drift is
# already under review and the run is a no-op. The remote branch (not a
# local state file) is the ledger, so the property survives losing
# ~/.local/state, a re-imaged host, or a second machine. If the branch
# exists but carries no PR — a previous run pushed and then died before
# `gh pr create` — the PR is opened for the existing branch instead of
# duplicating it.
#
# Env overrides — FOR THE TEST HARNESSES ONLY (tests/crontab-drift.nix
# and the failure lane in tests/base.nix). Production (the systemd user
# service) sets none of these:
#   CRONDRIFT_CRONTAB_BIN    crontab executable (stubbed in tests)
#   CRONDRIFT_DECLARED_FILE  rendered declaration to compare against
#   CRONDRIFT_BARE_REPO      nixos-config bare repo
#   CRONDRIFT_GH_BIN         gh executable (stubbed in tests)
#   CRONDRIFT_NOTIFY_BIN     notify-send executable (stubbed in tests)
#   CRONDRIFT_CONFIG_FILE    repo-relative file holding the crontab block
#   CRONDRIFT_REPO_SLUG      owner/name for gh
#   CRONDRIFT_BASE_REF       base branch to fork from
#   CRONDRIFT_STATE_DIR      notification-dedupe state

let
  # Nix-string escaper + anchor-insert, in Python because getting Nix
  # indented-string escaping right in sed/awk is how injection bugs are
  # born. See the module comment in the program itself.
  inserter = pkgs.writers.writePython3Bin "crontab-drift-insert" { } ''
    """Insert live-only crontab entries into a Nix indented string.

    usage: crontab-drift-insert CONFIG STRAY_FILE ANCHOR STAMP

    CONFIG      .nix file holding the crontab text block
    STRAY_FILE  newline-separated live-only entries, verbatim
    ANCHOR      substring identifying the single insertion-point line
    STAMP       provenance date for the inserted comment

    Exit codes: 0 inserted; 2 usage; 3 anchor missing or ambiguous;
    4 every entry already declared in the checkout (nothing to do).
    """
    import os
    import re
    import sys

    # Nix indented-string escaping. Inside an indented Nix string a
    # doubled single-quote ends it and a dollar-brace opens an
    # interpolation, so a live crontab line containing either would
    # inject arbitrary Nix into the config file — evaluation- and
    # activation-time code execution sourced from a file any process can
    # append to with `crontab -`, in a file where `config`, `pkgs` and
    # `lib` are all in scope. This is a security boundary, not tidiness.
    #
    # EVERY single quote is escaped, not just doubled ones. Escaping
    # only doubled quotes leaves a parity hole: with an ODD number of
    # quotes in front of an interpolation, the leftover quote joins the
    # two the escape adds, and Nix relexes that three-quote run as a
    # literal doubled quote followed by a LIVE interpolation. Verified
    # against the real evaluator: the escaped-only-doubled form of a
    # crontab line quoting a shell variable evaluated to "error:
    # undefined variable 'HOME'" instead of staying text. Quoting a
    # variable is ordinary in a crontab line, and this file has config,
    # pkgs and lib in scope, so the hole was reachable. Escaping EVERY
    # quote with the generic escape removes the class rather than one
    # instance of it.
    #
    # Spelled via chr() so this source contains none of the sequences
    # literally, which would otherwise need escaping again in the Nix
    # string that carries this program.
    Q1 = chr(39)
    BSLASH = chr(92)
    QUOTE_ESC = Q1 + Q1 + BSLASH + Q1
    INTERP = chr(36) + chr(123)
    INTERP_ESC = Q1 + Q1 + INTERP


    def nix_escape(text):
        # Quotes FIRST: the interpolation escape introduces a doubled
        # quote of its own, which must not then be re-escaped.
        return text.replace(Q1, QUOTE_ESC).replace(INTERP, INTERP_ESC)


    def main():
        if len(sys.argv) != 5:
            print(__doc__, file=sys.stderr)
            return 2
        config_path, stray_path, anchor, stamp = sys.argv[1:5]
        with open(config_path, encoding="utf-8") as handle:
            lines = handle.read().split("\n")
        with open(stray_path, encoding="utf-8") as handle:
            stray = [s.strip() for s in handle.read().split("\n") if s.strip()]
        if not stray:
            print("insert: no stray entries supplied", file=sys.stderr)
            return 2
        hits = [i for i, line in enumerate(lines) if anchor in line]
        if len(hits) != 1:
            print(
                "insert: anchor matched %d lines, expected exactly 1"
                % len(hits),
                file=sys.stderr,
            )
            return 3
        idx = hits[0]
        indent = re.match(r"[ \t]*", lines[idx]).group(0)
        # Skip entries the checkout already declares. Between a PR
        # merging and the host actually rebuilding, the entry is in
        # origin/main but still absent from the LIVE generation's
        # rendered crontab, so the drift is still "detected" — without
        # this filter the next run would open a second PR adding a line
        # that is already there.
        existing = set(ln.strip() for ln in lines)
        wanted = []
        for entry in stray:
            escaped = nix_escape(entry)
            if escaped in existing:
                print("skipped (already declared upstream): " + entry)
                continue
            wanted.append(escaped)
        if not wanted:
            print("insert: every entry is already declared in the checkout")
            return 4
        block = [
            indent + "# Added by crontab-drift-check on " + stamp
            + " — found live, not declared."
        ]
        for escaped in wanted:
            block.append(indent + escaped)
        lines[idx:idx] = block
        tmp_path = config_path + ".crondrift.tmp"
        with open(tmp_path, "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines))
        os.replace(tmp_path, config_path)
        for line in block:
            print("inserted: " + line.strip())
        return 0


    if __name__ == "__main__":
        sys.exit(main())
  '';
in
pkgs.writeShellApplication {
  name = "crontab-drift-check";
  runtimeInputs = with pkgs; [
    coreutils
    git
    gnugrep
    gawk
    jq
    inserter
  ];
  text = ''
    # Pin collation for the whole script. `sort` and `comm` MUST agree
    # on ordering or comm rejects its own input; sorting under C while
    # comm ran under the caller's locale is a real bug this had
    # (2026-08-08, found by the feature-VM smoke): a systemd user
    # session carries a UTF-8 locale, UTF-8 collation ignores
    # punctuation at the primary level, so C-sorted crontab entries
    # ("*/30 …" before "0 5 …") look unsorted to comm — it bailed with
    # "file 2 is not in sorted order" and the unit went red on a
    # perfectly clean crontab. Exported, not per-command, so no future
    # pipeline can be added without the pin. tests/crontab-drift.nix
    # case 12 is the regression guard.
    export LC_ALL=C

    CRONTAB_BIN="''${CRONDRIFT_CRONTAB_BIN:-/run/wrappers/bin/crontab}"
    DECLARED="''${CRONDRIFT_DECLARED_FILE:-$HOME/.config/crontab}"
    BARE="''${CRONDRIFT_BARE_REPO:-$HOME/Repos/nixos-config}"
    GH_BIN="''${CRONDRIFT_GH_BIN:-${pkgs.gh}/bin/gh}"
    NOTIFY_BIN="''${CRONDRIFT_NOTIFY_BIN:-${pkgs.libnotify}/bin/notify-send}"
    CONFIG_REL="''${CRONDRIFT_CONFIG_FILE:-home/jonathan-linux.nix}"
    REPO_SLUG="''${CRONDRIFT_REPO_SLUG:-jonathanmoregard/nixos-config}"
    BASE_REF="''${CRONDRIFT_BASE_REF:-main}"
    STATE_DIR="''${CRONDRIFT_STATE_DIR:-''${XDG_STATE_HOME:-$HOME/.local/state}/crontab-drift-check}"

    # Marker line inside the crontab text block that new entries are
    # inserted directly above. It is a crontab comment, so it is inert
    # in the live crontab and dropped by the normaliser below — no
    # feedback loop.
    ANCHOR="crontab-drift-check inserts newly-found live entries directly above this line"

    # Refuse to auto-write a runaway crontab. 50 entries / 16 KiB is far
    # above any plausible real drift; past that, something is wrong and
    # a human should look before a PR mangles the declaration.
    MAX_STRAY_LINES=50
    MAX_STRAY_BYTES=16384

    log() { echo "[crontab-drift] $*"; }

    # Log first — journald always works; the session bus may not.
    notify() {  # <urgency> <summary> <body>
      log "notify[$1] $2 — $3"
      if ! "$NOTIFY_BIN" -u "$1" "$2" "$3" >/dev/null 2>&1; then
        log "notify-send failed (no notification daemon on the session bus?) — journal only"
      fi
    }

    # Non-zero exit → the unit goes red → OnFailure fires the critical
    # desktop notification. Reserved for "I could not do my job".
    die() {
      log "FATAL: $*" >&2
      exit 1
    }

    tmp=""
    work=""
    cleanup() {
      if [ -n "$work" ] && [ -d "$work" ]; then
        git -C "$BARE" worktree remove --force "$work" >/dev/null 2>&1 || true
      fi
      if [ -d "$BARE" ]; then
        git -C "$BARE" worktree prune >/dev/null 2>&1 || true
      fi
      if [ -n "$tmp" ]; then
        rm -rf "$tmp"
      fi
    }
    trap cleanup EXIT

    tmp="$(mktemp -d -t crontab-drift.XXXXXX)"

    # ── read both sides ────────────────────────────────────────────────
    [ -r "$DECLARED" ] || die "declared crontab not readable at $DECLARED — the home-manager generation is broken or \$HOME is wrong"
    [ -x "$CRONTAB_BIN" ] || die "crontab binary not executable at $CRONTAB_BIN — cannot read the live crontab, so drift is undetectable"

    rc=0
    "$CRONTAB_BIN" -l >"$tmp/live.raw" 2>"$tmp/live.err" || rc=$?
    if [ "$rc" -ne 0 ]; then
      if grep -qi "no crontab for" "$tmp/live.err"; then
        log "live crontab is empty (no crontab installed for this user)"
        : >"$tmp/live.raw"
      else
        die "cannot read the live crontab via $CRONTAB_BIN (rc=$rc): $(tr '\n' ' ' <"$tmp/live.err")"
      fi
    fi

    # Drop comments (cron's own "DO NOT EDIT THIS FILE" banner, the
    # declaration's prose, this script's anchor), drop blanks, trim, and
    # compare as a SET — cron entry order is not semantic.
    normalise() {  # <src> <dst>
      LC_ALL=C awk '
        { sub(/[[:space:]]+$/, ""); sub(/^[[:space:]]+/, "") }
        /^#/  { next }
        /^$/  { next }
        { print }
      ' "$1" | LC_ALL=C sort -u >"$2"
    }

    normalise "$tmp/live.raw" "$tmp/live.norm"
    normalise "$DECLARED" "$tmp/declared.norm"

    comm -23 "$tmp/live.norm" "$tmp/declared.norm" >"$tmp/live-only"
    comm -13 "$tmp/live.norm" "$tmp/declared.norm" >"$tmp/declared-only"

    log "live entries: $(wc -l <"$tmp/live.norm"), declared entries: $(wc -l <"$tmp/declared.norm")"

    # Notify at most once per distinct finding: an hourly critical popup
    # repeating a finding the user has already seen trains them to
    # ignore the channel, which is the failure mode this unit exists to
    # prevent.
    # The digest comes from the FINDING (a file listing the entries),
    # never from the message text: the message only carries a count, so
    # digesting it would dedupe two entirely different drift sets that
    # happen to be the same size into a single notification.
    notify_once() {  # <key> <urgency> <summary> <body> <finding-file>
      local key="$1" urgency="$2" summary="$3" body="$4" finding="$5"
      local digest state
      digest="$(sha256sum <"$finding" | cut -c1-16)"
      state="$STATE_DIR/$key.notified"
      # State is an optimisation, never a gate: an unwritable state dir
      # must degrade to "notify every run", never to "stay silent".
      mkdir -p "$STATE_DIR" 2>/dev/null || true
      if [ -r "$state" ] && [ "$(cat "$state")" = "$digest" ]; then
        log "finding '$key' unchanged since the last notification — journal only"
        return 0
      fi
      notify "$urgency" "$summary" "$body"
      printf '%s' "$digest" >"$state" 2>/dev/null || true
    }

    # ── direction 2: declared but NOT live ─────────────────────────────
    # Nothing to add to the declaration — this means activation did not
    # install the crontab, or something overwrote it. Surface it; the
    # fix is a rebuild, not a PR.
    if [ -s "$tmp/declared-only" ]; then
      log "DECLARED BUT NOT LIVE — activation did not install these, or the live crontab was clobbered:"
      while IFS= read -r entry; do
        if [ -n "$entry" ]; then log "  missing-live: $entry"; fi
      done <"$tmp/declared-only"
      notify_once missing-live critical \
        "Crontab drift: declared entries are not running" \
        "$(wc -l <"$tmp/declared-only") declared cron entries are absent from the live crontab. Fix: nixos-rebuild switch (re-runs installCrontab). Detail: journalctl --user -u crontab-drift-check" \
        "$tmp/declared-only"
    fi

    # ── direction 1: live but NOT declared ─────────────────────────────
    # Classify before proposing. Only plain schedule entries are safe to
    # auto-file; env assignments and anything unrecognised go to a human.
    : >"$tmp/stray"
    : >"$tmp/unclassified"
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      if printf '%s' "$entry" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*='; then
        printf '%s\n' "$entry" >>"$tmp/unclassified"
      elif printf '%s' "$entry" | grep -Eq '^@(reboot|yearly|annually|monthly|weekly|daily|midnight|hourly)[[:space:]]+[^[:space:]]'; then
        printf '%s\n' "$entry" >>"$tmp/stray"
      elif printf '%s' "$entry" | grep -Eq '^[^[:space:]]+([[:space:]]+[^[:space:]]+){4}[[:space:]]+[^[:space:]]'; then
        printf '%s\n' "$entry" >>"$tmp/stray"
      else
        printf '%s\n' "$entry" >>"$tmp/unclassified"
      fi
    done <"$tmp/live-only"

    if [ -s "$tmp/unclassified" ]; then
      log "LIVE-ONLY lines that are not schedule entries — never auto-filed, a human decides:"
      while IFS= read -r entry; do
        if [ -n "$entry" ]; then log "  unclassified: $entry"; fi
      done <"$tmp/unclassified"
      notify_once unclassified critical \
        "Crontab drift: unclassified live-only lines" \
        "$(wc -l <"$tmp/unclassified") live-only crontab lines are not schedule entries (env assignments?) and were NOT proposed. Detail: journalctl --user -u crontab-drift-check" \
        "$tmp/unclassified"
    fi

    if [ ! -s "$tmp/stray" ]; then
      # Don't claim a clean bill of health while findings sit above it:
      # with an empty live crontab every declared entry is missing and
      # "matches the declaration" would be actively wrong.
      if [ -s "$tmp/declared-only" ] || [ -s "$tmp/unclassified" ]; then
        log "nothing to propose — no live-only schedule entries (see the findings above)"
      else
        log "no live-only schedule entries — the live crontab matches the declaration"
      fi
      exit 0
    fi

    stray_count="$(wc -l <"$tmp/stray")"
    stray_bytes="$(wc -c <"$tmp/stray")"
    log "LIVE BUT NOT DECLARED ($stray_count entries) — these die on the next nixos-rebuild switch:"
    while IFS= read -r entry; do
      if [ -n "$entry" ]; then log "  stray: $entry"; fi
    done <"$tmp/stray"

    if [ "$stray_count" -gt "$MAX_STRAY_LINES" ] || [ "$stray_bytes" -gt "$MAX_STRAY_BYTES" ]; then
      die "refusing to auto-file $stray_count entries / $stray_bytes bytes of drift (caps: $MAX_STRAY_LINES / $MAX_STRAY_BYTES) — inspect the live crontab by hand"
    fi

    # ── idempotence key ────────────────────────────────────────────────
    drift_hash="$(LC_ALL=C sort "$tmp/stray" | sha256sum | cut -c1-12)"
    branch="crontab-drift/$drift_hash"
    case "$branch" in
      "$BASE_REF"|main|master)
        die "refusing to use '$branch' as a drift branch" ;;
    esac
    log "drift hash $drift_hash → branch $branch"

    # ── everything below needs the repo and gh; drift we cannot file is
    #    a hard failure, because unfiled drift is exactly the silence
    #    this unit exists to break ─────────────────────────────────────
    [ -d "$BARE" ] || die "drift detected but the nixos-config repo is missing at $BARE — cannot open a PR"
    "$GH_BIN" auth status >/dev/null 2>&1 || die "drift detected but gh is unavailable/unauthenticated — cannot open a PR (fix: gh auth login)"
    git -C "$BARE" fetch --quiet origin "$BASE_REF" || die "drift detected but 'git fetch origin $BASE_REF' failed in $BARE — cannot open a PR"

    pr_needed=1
    push_needed=1
    if git -C "$BARE" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
      push_needed=0
      if ! pr_json="$("$GH_BIN" pr list --repo "$REPO_SLUG" --head "$branch" --state all --json number,state 2>/dev/null)"; then
        die "branch $branch already exists on origin but 'gh pr list' failed — cannot confirm whether this drift is already under review"
      fi
      if ! pr_count="$(jq 'length' <<<"$pr_json" 2>/dev/null)"; then
        die "gh pr list output was not parseable JSON — cannot confirm whether this drift is already under review"
      fi
      if [ "$pr_count" -gt 0 ]; then
        open_pr="$(jq -r '[.[] | select(.state == "OPEN")][0].number // empty' <<<"$pr_json")"
        merged_pr="$(jq -r '[.[] | select(.state == "MERGED")][0].number // empty' <<<"$pr_json")"
        any_pr="$(jq -r '.[0].number' <<<"$pr_json")"
        if [ -n "$open_pr" ]; then
          log "this exact drift is already under review as PR #$open_pr on $branch — nothing to do"
          exit 0
        fi
        if [ -n "$merged_pr" ]; then
          # Merged upstream but the live generation predates it, so the
          # entry is still missing from the local declaration. Harmless
          # and self-clearing at the next switch — say so rather than
          # opening a second PR for it.
          log "PR #$merged_pr for this drift is merged; the local generation predates it — rebuild to clear (no new PR)"
          exit 0
        fi
        # Every PR for this drift was CLOSED without merging, yet the
        # entries are still live. Re-filing would nag; staying silent is
        # how the four-month outage happened. Say it once per distinct
        # finding and stay green.
        log "PR #$any_pr for this drift was closed without merging, but the entries are STILL LIVE — not re-filing"
        notify_once rejected-still-live critical \
          "Crontab drift: rejected entries are still live" \
          "PR #$any_pr was closed without merging, but $stray_count live-only cron entries are still in the crontab and will be deleted at the next rebuild. Either re-open the PR or remove them with crontab -e. Detail: journalctl --user -u crontab-drift-check" \
          "$tmp/stray"
        exit 0
      fi
      log "branch $branch exists on origin but carries no PR (an earlier run pushed then died) — opening the PR for it"
      pr_needed=1
    fi

    stamp="$(date -Iseconds)"
    day="$(date +%Y-%m-%d)"
    host="$(uname -n)"

    if [ "$push_needed" -eq 1 ]; then
      work="$tmp/checkout"
      git -C "$BARE" worktree add --quiet --detach "$work" "origin/$BASE_REF" \
        || die "could not create a temporary worktree from origin/$BASE_REF"
      [ -f "$work/$CONFIG_REL" ] || die "$CONFIG_REL not found in the origin/$BASE_REF checkout"

      insert_rc=0
      crontab-drift-insert "$work/$CONFIG_REL" "$tmp/stray" "$ANCHOR" "$day" \
        || insert_rc=$?
      if [ "$insert_rc" -eq 4 ]; then
        # Merged upstream with the branch auto-deleted, so ls-remote saw
        # nothing — but origin/main already declares every stray entry.
        # Opening a PR here would add duplicate lines.
        log "every stray entry is already declared in origin/$BASE_REF; the live generation just predates it — rebuild to clear (no PR opened)"
        exit 0
      elif [ "$insert_rc" -ne 0 ]; then
        die "could not insert the stray entries into $CONFIG_REL (rc=$insert_rc) — is the anchor comment ('$ANCHOR') still present exactly once?"
      fi

      # Enumerate rather than assert: the pre-push checklist gate wants a
      # true statement about the diff, and a cron command could legitimately
      # contain one of these tokens.
      markers="$( { grep -oE 'sh -c|ExecStart|activationScripts|writeShellApplication|mkIf' "$tmp/stray" || true; } | LC_ALL=C sort -u | tr '\n' ' ')"
      [ -n "$markers" ] || markers="none"

      # Backticks below are markdown/prose, not command substitution.
      # shellcheck disable=SC2016
      {
        printf 'feat(cron): declare %s live-only crontab entry(ies)\n\n' "$stray_count"
        printf 'Opened automatically by crontab-drift-check on %s at %s.\n\n' "$host" "$stamp"
        printf 'These entries exist in the LIVE user crontab but not in\n'
        printf '%s, so the next `nixos-rebuild switch` deletes\n' "$CONFIG_REL"
        printf 'them: home.activation.installCrontab rewrites the live crontab from\n'
        printf 'the declaration. Same failure that killed the RSI daily reviewer for\n'
        printf 'four months.\n\nEntries added:\n\n'
        sed -e 's/^/  /' "$tmp/stray"
        printf '\nThe declaration is the source of truth. If an entry here should NOT\n'
        printf 'be running, close this PR and remove it from the live crontab —\n'
        printf 'do not merge to make the warning go away.\n\n'
        printf 'Pre-push checklist:\n'
        printf -- '- Type: risky\n'
        printf -- '- Rebased on origin/%s: yes\n' "$BASE_REF"
        printf -- '- Local gate: not run — machine-generated commit; CI runs eval/build/vm-minimal on this PR\n'
        printf -- '- Interactive smoke (nixos-agent-testing): N/A — crontab text lines only, no new executable path in this diff\n'
        printf -- '- Advisor review (advice-refine-test-loop): N/A — single-hunk data change; human review before merge is the gate\n'
        printf -- '- feature-vm.nix modified: no\n'
        printf -- '- Risky markers in diff: %s\n' "$markers"
        printf -- '- Behavioural evidence: `%s -l` on %s at %s listed the entries above; they are absent from %s in origin/%s\n' \
          "$CRONTAB_BIN" "$host" "$stamp" "$CONFIG_REL" "$BASE_REF"
      } >"$tmp/commit-msg"

      git -C "$work" add -- "$CONFIG_REL" || die "git add failed"
      git -C "$work" \
        -c user.name="crontab-drift-check" \
        -c user.email="crontab-drift-check@localhost" \
        commit --quiet -F "$tmp/commit-msg" || die "git commit failed"

      # Explicit refspec, no --force, branch name provably not the base
      # ref (guarded above). There is no code path here that can write
      # to main.
      git -C "$work" push --quiet origin "HEAD:refs/heads/$branch" \
        || die "pushing $branch to origin failed"
      log "pushed $branch"

      git -C "$BARE" worktree remove --force "$work" >/dev/null 2>&1 || true
      work=""
    fi

    if [ "$pr_needed" -eq 1 ]; then
      # Backticks below are markdown, not command substitution.
      # shellcheck disable=SC2016
      {
        printf '## Live crontab drift — %s entry(ies) found live but not declared\n\n' "$stray_count"
        printf 'Opened automatically by `crontab-drift-check` (host `%s`, %s).\n\n' "$host" "$stamp"
        printf '### Entries\n\n```\n'
        cat "$tmp/stray"
        printf '```\n\n### Why this matters\n\n'
        printf '`home.activation.installCrontab` rewrites the live crontab from\n'
        printf '`%s` on every `nixos-rebuild switch`. An entry that\n' "$CONFIG_REL"
        printf 'is live but not declared is deleted at the next rebuild, silently.\n'
        printf 'That is how the RSI daily reviewer stayed dead from 2026-04-17 to\n'
        printf '2026-08-01, and how the permission-ledger evaluator nearly went the\n'
        printf 'same way.\n\n### Review guidance\n\n'
        printf 'The DECLARATION is the source of truth — this PR is a proposal, not\n'
        printf 'a record. If an entry above should not be running at all, close this\n'
        printf 'PR and remove it from the live crontab instead of merging.\n\n'
        printf 'Entry text was escaped for Nix indented strings before insertion\n'
        printf '(doubled-quote and dollar-brace sequences), so a crontab line cannot\n'
        printf 'inject Nix expressions into the config.\n\n### Idempotence\n\n'
        printf 'The branch name carries a sha256 prefix of the sorted stray entries\n'
        printf '(`%s`). Later runs that see the same drift find the branch\n' "$drift_hash"
        printf 'on origin and do nothing, so this PR is not re-opened hourly.\n'
      } >"$tmp/pr-body"

      if ! pr_url="$(cd "$tmp" && "$GH_BIN" pr create \
            --repo "$REPO_SLUG" \
            --head "$branch" \
            --title "feat(cron): declare $stray_count live-only crontab entry(ies)" \
            --body-file "$tmp/pr-body" 2>&1)"; then
        die "branch $branch is pushed but 'gh pr create' failed: $(printf '%s' "$pr_url" | tr '\n' ' ')"
      fi
      log "opened PR: $pr_url"
      notify normal "Crontab drift: PR opened for review" \
        "$stray_count live-only cron entry(ies) would be deleted by the next rebuild. Review: $pr_url"
    fi

    log "done"
  '';
}
