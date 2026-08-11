{ pkgs }:

# add-secret — one-command wrapper for adding a new agenix-rekey secret.
#
# Collapses the manual flow documented in
# home/claude-skills/nixos-agenix-secret/SKILL.md (edit host file →
# `edit-view -- edit` → `rekey` → git add/commit/push/PR) into a single
# invocation.
#
# The human still has to click MERGE in the GitHub UI — that's the
# deliberate gesture per the nixos-deploy pipeline; every secret change
# is auto-deployed on merge, and the click stays a conscious step.
#
# Env overrides — FOR THE TEST HARNESS ONLY (tests/add-secret-smoke.nix
# and the manual pre-PR smoke on real dellan). Production invocations
# must not set these:
#   ADD_SECRET_TEST_MODE=1      skip `nix eval`, `rekey`, git/gh — used
#                               to exercise validation + insertion in
#                               the nix sandbox where those network
#                               / eval-time steps can't run
#   ADD_SECRET_SKIP_GIT=1       run the real nix eval + rekey but skip
#                               the git commit + push + gh pr create.
#                               Used to smoke the happy path against
#                               the real flake without opening a bogus
#                               PR; the caller is expected to revert
#                               the workspace afterwards.
#   ADD_SECRET_MARKER=<str>     override the host-file insertion marker
#                               (defaults to `# add-secret:insert-here`)
#   ADD_SECRET_STDIN_OK=1       allow prompt-mode without /dev/tty
#                               (harness synthesises stdin — never set
#                               interactively; kills the confirm-reentry
#                               safety)
pkgs.writeShellApplication {
  name = "add-secret";
  runtimeInputs = with pkgs; [
    age
    git
    gh
    wl-clipboard
    coreutils
    gnugrep
    gnused
    gawk
  ];
  text = ''
    # -------------------------------------------------------------------
    # constants + defaults
    # -------------------------------------------------------------------
    NAME=""
    HOST="dellan"
    OWNER="jonathan"
    GROUP="users"
    MODE="0400"
    # SOURCE stays empty until either an explicit --from-* / --prompt
    # flag sets it, OR the post-parse auto-detect below resolves it
    # based on whether stdin is a TTY. This distinction matters: if the
    # user pipes data in without any flag, we should read stdin — not
    # sit blocked on a prompt that never gets typed.
    SOURCE=""
    SOURCE_EXPLICIT=0
    MARKER="''${ADD_SECRET_MARKER:-# add-secret:insert-here}"
    TEST_MODE="''${ADD_SECRET_TEST_MODE:-0}"
    SKIP_GIT="''${ADD_SECRET_SKIP_GIT:-0}"

    die() { echo "add-secret: $*" >&2; exit 1; }
    log() { echo "add-secret: $*" >&2; }

    usage() {
      cat >&2 <<'HELP'
Usage:
  add-secret <name> [--host <host>] [--owner <user>] [--group <group>]
                    [--mode <mode>] [--from-stdin | --from-clipboard | --prompt]

Defaults: --host dellan --owner jonathan --group users --mode 0400
Value source: auto-detected — piped stdin uses --from-stdin, otherwise --prompt.
              Pass one of --from-* / --prompt to override.

Examples:
  pass show anthropic-api-key | add-secret anthropic-api-key
  wl-paste                    | add-secret openai-api-key
  add-secret gemini-api-key                       # interactive prompt
  add-secret gemini-api-key --from-clipboard      # explicit wl-paste

Must be run from a nixos-config worktree root (e.g.
~/Repos/nixos-config-worktrees/<slug>). Creates the source .age file,
inserts the age.secrets.<name> declaration into hosts/<host>/default.nix
above the `# add-secret:insert-here` marker, rekeys, commits on the
current feature branch, pushes, opens a PR, and prints the PR URL.
HELP
    }

    # -------------------------------------------------------------------
    # parse args
    # -------------------------------------------------------------------
    while [ $# -gt 0 ]; do
      case "$1" in
        --host)           HOST="$2";  shift 2 ;;
        --owner)          OWNER="$2"; shift 2 ;;
        --group)          GROUP="$2"; shift 2 ;;
        --mode)           MODE="$2";  shift 2 ;;
        --from-stdin)     SOURCE="stdin";     SOURCE_EXPLICIT=1; shift ;;
        --from-clipboard) SOURCE="clipboard"; SOURCE_EXPLICIT=1; shift ;;
        --prompt)         SOURCE="prompt";    SOURCE_EXPLICIT=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        --) shift; break ;;
        -*) usage; die "unknown flag: $1" ;;
        *)
          [ -z "$NAME" ] || die "unexpected extra positional arg: $1"
          NAME="$1"
          shift
          ;;
      esac
    done

    [ -n "$NAME" ] || { usage; die "missing <name>"; }

    # -------------------------------------------------------------------
    # resolve value source
    #
    # Explicit --from-* / --prompt always wins. Otherwise: if stdin is
    # a TTY, prompt the user; if stdin is piped/redirected, read from
    # it. This makes the pipe idioms below Just Work with no flag:
    #
    #   pass show <key> | add-secret <key>
    #   wl-paste        | add-secret <key>
    #   add-secret <key> <<< "$val"
    #
    # while `add-secret <key>` at an interactive shell still prompts.
    # We log to stderr when auto-detect picks stdin so it isn't silent
    # magic (harder to debug when a paste doesn't land).
    # -------------------------------------------------------------------
    if [ "$SOURCE_EXPLICIT" = "0" ]; then
      if [ -t 0 ]; then
        SOURCE="prompt"
      else
        SOURCE="stdin"
        log "reading value from stdin (piped)"
      fi
    fi

    # -------------------------------------------------------------------
    # validate name
    # -------------------------------------------------------------------
    if ! printf '%s' "$NAME" | grep -Eq '^[a-z][a-z0-9-]*$'; then
      die "invalid name '$NAME' — must match ^[a-z][a-z0-9-]*$ (lowercase kebab-case)"
    fi

    # -------------------------------------------------------------------
    # preflight: cwd must be a nixos-config worktree root
    # -------------------------------------------------------------------
    for req in flake.nix hosts secrets .git; do
      if [ ! -e "$req" ]; then
        die "cwd is not a nixos-config worktree root ($req missing). \
cd into ~/Repos/nixos-config-worktrees/<slug> and rerun."
      fi
    done

    HOST_FILE="hosts/$HOST/default.nix"
    [ -f "$HOST_FILE" ] || die "no host file at $HOST_FILE"

    # -------------------------------------------------------------------
    # refuse if already declared / file already exists
    # -------------------------------------------------------------------
    if grep -Eq "age\.secrets\.$NAME([.= ]|\$)" "$HOST_FILE"; then
      die "age.secrets.$NAME is already declared in $HOST_FILE.
To edit its value, use the manual edit path:
  EDITOR=nano nix run .#agenix-rekey.x86_64-linux.edit-view -- edit secrets/$NAME.age"
    fi

    AGE_FILE="secrets/$NAME.age"
    if [ -e "$AGE_FILE" ]; then
      die "$AGE_FILE already exists on disk. Refusing to overwrite."
    fi

    # -------------------------------------------------------------------
    # read value
    # -------------------------------------------------------------------
    read_value() {
      case "$SOURCE" in
        prompt)
          local v1="" v2=""
          # Actually TRY to open /dev/tty — `[ -r /dev/tty ]` returns
          # true in sandboxes where the device node exists but isn't
          # connected to anything (open() then fails with ENXIO).
          # `exec 3</dev/tty` returns non-zero on that ENXIO, which is
          # what we key off.
          if exec 3</dev/tty 2>/dev/null; then
            printf 'value for %s: ' "$NAME" >&2
            IFS= read -rs v1 <&3
            printf '\n' >&2
            printf 'confirm       : ' >&2
            IFS= read -rs v2 <&3
            printf '\n' >&2
            exec 3<&-
            [ "$v1" = "$v2" ] || die "values differ; aborting"
          elif [ "''${ADD_SECRET_STDIN_OK:-0}" = "1" ]; then
            # harness path — single read from stdin, no confirm
            IFS= read -r v1 || true
          else
            die "--prompt requires a controlling tty. Pipe the value in (e.g. \`pass show <key> | add-secret <name>\`) or pass --from-stdin / --from-clipboard when running non-interactively."
          fi
          printf '%s' "$v1"
          ;;
        clipboard)
          command -v wl-paste >/dev/null 2>&1 || die "wl-paste not available (not on Wayland?)"
          if ! wl-paste --no-newline; then
            die "wl-paste failed — is a Wayland session running?"
          fi
          ;;
        stdin)
          cat
          ;;
      esac
    }

    RAW_VALUE=$(read_value)
    [ -n "$RAW_VALUE" ] || die "value is empty; aborting"

    # -------------------------------------------------------------------
    # sanitize: strip trailing newline; strip KEY= prefix on shape
    # -------------------------------------------------------------------
    # Trim a single trailing newline if present.
    RAW_VALUE="''${RAW_VALUE%$'\n'}"

    # If the value is a single line matching KEY=VALUE (env-var shape),
    # strip the KEY= prefix. Consumers read the raw value with $(< file)
    # and export the env var themselves; storing KEY= would double-wrap.
    # Use bash pattern matching, not `grep $'\n'` — grep treats a newline
    # pattern as an empty match (matches every input).
    case "$RAW_VALUE" in
      *$'\n'*)
        : # multi-line — leave as-is
        ;;
      *)
        if printf '%s' "$RAW_VALUE" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*='; then
          stripped_key="''${RAW_VALUE%%=*}"
          log "value looks like ''${stripped_key}=… — stripping to just the value (agenix stores raw)"
          RAW_VALUE="''${RAW_VALUE#*=}"
        fi
        ;;
    esac
    [ -n "$RAW_VALUE" ] || die "value is empty after sanitisation; aborting"

    # -------------------------------------------------------------------
    # extract master pubkey from modules/nixos/agenix-rekey-common.nix
    # -------------------------------------------------------------------
    PUBKEY_FILE="modules/nixos/agenix-rekey-common.nix"
    [ -f "$PUBKEY_FILE" ] || die "expected $PUBKEY_FILE — is this really the nixos-config repo?"
    PUBKEY_LINE=$(grep -E '^[[:space:]]*pubkey[[:space:]]*=[[:space:]]*"' "$PUBKEY_FILE" | head -n1 || true)
    [ -n "$PUBKEY_LINE" ] || die "no 'pubkey = \"...\"' line found in $PUBKEY_FILE"
    PUBKEY=$(printf '%s' "$PUBKEY_LINE" | sed -E 's/^[[:space:]]*pubkey[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/')
    [ -n "$PUBKEY" ] || die "extracted master pubkey is empty"

    # -------------------------------------------------------------------
    # encrypt to secrets/<name>.age
    # -------------------------------------------------------------------
    if ! printf '%s' "$RAW_VALUE" | age -r "$PUBKEY" -o "$AGE_FILE"; then
      rm -f "$AGE_FILE"
      die "age encryption failed"
    fi
    log "wrote encrypted source: $AGE_FILE"

    # -------------------------------------------------------------------
    # insert declaration above the marker line
    # -------------------------------------------------------------------
    if ! grep -qF "$MARKER" "$HOST_FILE"; then
      rm -f "$AGE_FILE"
      die "marker '$MARKER' not found in $HOST_FILE — cannot safely insert.
Add the marker on its own line where new age.secrets should go, or fall back to the manual path in home/claude-skills/nixos-agenix-secret/SKILL.md."
    fi

    HOST_BACKUP="$HOST_FILE.add-secret-backup"
    cp "$HOST_FILE" "$HOST_BACKUP"

    # awk: write the new block on the first line that contains the marker.
    awk -v name="$NAME" -v owner="$OWNER" -v group="$GROUP" -v mode="$MODE" \
        -v marker="$MARKER" '
      !inserted && index($0, marker) {
        printf "  age.secrets.%s = {\n", name
        printf "    rekeyFile = ../../secrets/%s.age;\n", name
        printf "    owner = \"%s\";\n", owner
        printf "    group = \"%s\";\n", group
        printf "    mode = \"%s\";\n", mode
        printf "  };\n\n"
        inserted = 1
      }
      { print }
    ' "$HOST_BACKUP" > "$HOST_FILE"

    if ! grep -q "age.secrets.$NAME " "$HOST_FILE"; then
      mv "$HOST_BACKUP" "$HOST_FILE"
      rm -f "$AGE_FILE"
      die "insertion produced no age.secrets.$NAME declaration — awk failed. Reverted."
    fi
    log "inserted age.secrets.$NAME block into $HOST_FILE (above marker)"

    revert_all() {
      [ -f "$HOST_BACKUP" ] && mv "$HOST_BACKUP" "$HOST_FILE"
      rm -f "$AGE_FILE"
      # unstage the age file if we staged it
      git rm --cached --quiet "$AGE_FILE" 2>/dev/null || true
    }

    # -------------------------------------------------------------------
    # sanity: `nix eval` the new attr — proves the module still parses
    # AND that the new secret is visible under the nixos config.
    # (Skipped in TEST_MODE; the sandbox has no way to eval a full flake.)
    # -------------------------------------------------------------------
    if [ "$TEST_MODE" != "1" ]; then
      # Stage the new .age file so flake eval sees it; untracked files
      # are excluded from the flake source tree.
      git add -- "$AGE_FILE" "$HOST_FILE"
      if ! nix eval --raw ".#nixosConfigurations.$HOST.config.age.secrets.$NAME.rekeyFile" >/dev/null 2>eval.err; then
        log "nix eval failed after inserting age.secrets.$NAME:"
        sed 's/^/  /' eval.err >&2 || true
        revert_all
        rm -f eval.err
        die "reverted host file + removed $AGE_FILE — nothing to commit."
      fi
      rm -f eval.err
      log "nix eval ok"
    fi

    # backup no longer needed — commit path is now the only exit
    rm -f "$HOST_BACKUP"

    # -------------------------------------------------------------------
    # rekey — regenerate per-host copies under secrets/rekeyed/<host>/
    # -------------------------------------------------------------------
    if [ "$TEST_MODE" != "1" ]; then
      log "running agenix-rekey rekey…"
      if ! nix run ".#agenix-rekey.x86_64-linux.rekey"; then
        die "rekey failed. Workspace left as-is; inspect + rerun 'nix run .#agenix-rekey.x86_64-linux.rekey', or 'git reset --hard' to abort."
      fi
    fi

    # -------------------------------------------------------------------
    # git commit + push + PR
    # -------------------------------------------------------------------
    if [ "$TEST_MODE" != "1" ] && [ "$SKIP_GIT" != "1" ]; then
      branch=$(git rev-parse --abbrev-ref HEAD)
      if [ "$branch" = "main" ] || [ "$branch" = "HEAD" ]; then
        die "refusing to commit on '$branch' — create a feature branch first (git switch -c feat/<slug>)."
      fi

      git add -A
      git commit -m "secret: add $NAME

Adds age.secrets.$NAME on $HOST (owner=$OWNER, group=$GROUP, mode=$MODE).
Generated by \`add-secret\`.

Pre-push checklist:
- Type: risky
- Rebased on origin/main: yes
- Local gate: N/A — secret-only addition; VM gate does not exercise runtime read of a new .age file (no consumer yet)
- Interactive smoke (nixos-agent-testing): N/A — pure data addition; no branching logic to drive
- Advisor review (advice-refine-test-loop): N/A — mechanical add-secret invocation
- feature-vm.nix modified: no
- Risky markers in diff: age.secrets.$NAME declaration
- Behavioural evidence: 'nix eval .#nixosConfigurations.$HOST.config.age.secrets.$NAME.rekeyFile' returned a store path; 'agenix-rekey.rekey' produced secrets/rekeyed/$HOST/<hash>-$NAME.age
"

      git push -u origin "$branch"

      pr_body=$(cat <<PRBODY
Adds \`age.secrets.$NAME\` on host **$HOST** (owner=$OWNER, group=$GROUP, mode=$MODE).

Generated by \`add-secret\`. Consumers of the secret are not wired in this PR — that lands in a follow-up commit.

**Merging deploys automatically** via \`nixos-deploy.service\` on dellan.
PRBODY
      )

      if ! pr_url=$(gh pr create --title "secret: add $NAME" --body "$pr_body" 2>&1); then
        die "gh pr create failed: $pr_url"
      fi

      # Prominent PR-URL banner — the actionable "what next" for the
      # user. TTY branch adds bold ANSI + an OSC 8 hyperlink so kitty /
      # wezterm / iTerm2 / foot render it as a clickable link; non-TTY
      # (piped into a log or captured by an agent) gets plain text.
      log "rekeyed, committed, pushed."
      printf '\n' >&2
      if [ -t 1 ]; then
        printf '  Merge to deploy \xe2\x86\x92\n' >&2
        # \e]8;;<url>\e\\<visible>\e]8;;\e\\ — OSC 8 hyperlink.
        # Wrap the visible text in bold too so it stands out on plain
        # terminals that ignore the OSC 8 sequence.
        printf '  \x1b]8;;%s\x1b\\\x1b[1m%s\x1b[0m\x1b]8;;\x1b\\\n' "$pr_url" "$pr_url" >&2
      else
        printf '  Merge to deploy ->\n' >&2
        printf '  %s\n' "$pr_url" >&2
      fi
      printf '\n' >&2
      log "Auto-deploy fires on push:main."
    elif [ "$SKIP_GIT" = "1" ]; then
      log "SKIP_GIT=1 — skipped git / gh (rekey ran; workspace has staged + rekeyed files for you to inspect + revert)"
    else
      log "TEST_MODE=1 — skipped nix eval / rekey / git / gh"
    fi
  '';
}
