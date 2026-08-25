{ config, pkgs, lib, ... }:
let
  # Wellbeing tracker cron jobs need python-dateutil (habit-tracker.py)
  # plus stdlib. Cron's PATH is `/usr/bin:/bin` which has no `python3`
  # on NixOS, so the .py invocations need an absolute store path.
  wellbeingPython = pkgs.python3.withPackages (ps: with ps; [ python-dateutil ]);

  # PATH for cron jobs. Vixie-cron parses `NAME=value` lines at the top
  # of the crontab as env assignments (no shell expansion IN THOSE ENV
  # LINES — `$HOME`, `~` and systemd `%h` specifiers don't work there;
  # only Nix interpolation does, evaluated at activation time). Command
  # lines are different: cron hands them to SHELL, so `$HOME` in a
  # command field expands normally.
  # nix-profile paths first so user-installed binaries win over the
  # system; /run/wrappers/bin last so a cron job can't accidentally
  # resolve to a setuid wrapper ahead of its nix-profile equivalent.
  cronPath = lib.concatStringsSep ":" [
    "${config.home.homeDirectory}/.nix-profile/bin"
    "/etc/profiles/per-user/${config.home.username}/bin"
    "/run/current-system/sw/bin"
    "/run/wrappers/bin"
    "/usr/bin"
    "/bin"
  ];

  # RSI daily reviewer. Three stacked failures killed the naive
  # `claude --print --allowedTools "... Write(...)"` cron approach:
  #   1. path-scoped Write(...) grants passed via --allowedTools never
  #      register headless (probed 2026-08-01: unscoped "Write" writes,
  #      "Write(/tmp/x/*)" and "Write(/tmp/x/**)" both deny);
  #   2. even a registered Write is refused for any path under ~/.claude/
  #      by Claude Code's built-in sensitive-path gate, which --print
  #      short-circuits from ask into deny (probed: --allowedTools,
  #      --settings allow-rule and unscoped grants all lose to it);
  #   3. `crontab -e` installs are wiped on every rebuild (see the
  #      crontab comment below).
  # So the reviewer model runs READ-ONLY (Read/Glob/Grep — which also
  # means a prompt-injected transcript can't make it write anywhere) and
  # emits proposals as delimited stdout blocks; a trusted sink parses
  # and persists them. Proposer emits, pipeline persists.
  #
  # The sink enforces: basename-only *.md filenames (no traversal), no
  # overwrite of existing proposals, 64 KiB body cap, 10 proposals per
  # run. Model output is downstream of untrusted transcript content, so
  # every one of these is a security boundary, not tidiness.
  rsiProposalSink = pkgs.writers.writePython3Bin "rsi-proposal-sink" { } ''
    import os
    import re
    import sys
    from pathlib import Path

    # Exit codes: 0 clean; 2 anomaly (reject/truncation/missing-END) so
    # the wrapper preserves the raw model output for forensics — a
    # bad-model night must stay distinguishable from a quiet good one.
    anomalies = 0
    # Cron sets no LANG; don't let a locale-dependent stdin encoding
    # crash the sink on non-ASCII prose.
    sys.stdin.reconfigure(encoding="utf-8", errors="replace")
    dest = Path(sys.argv[1])
    # mode applies to the LEAF only (parents get umask); fine here, the
    # parent chain lives under ~/.claude which is already 0700.
    dest.mkdir(parents=True, exist_ok=True, mode=0o700)
    # 2 MiB stdin cap: 10 proposals x 64 KiB bodies + delimiter/prose
    # slack. A runaway model can't OOM the sink or the scan.
    text = sys.stdin.read(2 * 1024 * 1024)
    if sys.stdin.read(1):
        print("sink: WARNING stdin exceeded 2MiB cap; trailing output dropped")
        anomalies += 1
    # Line state machine, NOT a multiline regex: a non-greedy regex body
    # would glue proposals together when the model omits one END marker,
    # then lose them all to the size cap. Here a missing END rejects
    # only the block it belongs to.
    header = re.compile(r"^===PROPOSAL: (.*?)===$")
    # Lowercase kebab only — matches both known proposal shapes
    # (YYYY-MM-DD-<slug>.md, monthly-themes-YYYY-MM.md) and rejects
    # squat-bait like CLAUDE.md / README.md as a side effect.
    name_ok = re.compile(r"^[a-z0-9][a-z0-9-]{0,100}\.md$")
    blocks = []
    name = None
    buf = []
    for ln in text.split("\n"):
        m = header.match(ln)
        if m:
            if name is not None:
                print("sink: rejected %r (missing END marker)" % name)
                anomalies += 1
            name = m.group(1).strip()
            buf = []
            continue
        if ln == "===END PROPOSAL===":
            if name is not None:
                blocks.append((name, "\n".join(buf) + "\n"))
                name = None
            continue
        if name is not None:
            buf.append(ln)
    if name is not None:
        print("sink: rejected %r (missing END marker)" % name)
        anomalies += 1
    written = 0
    for fname, body_s in blocks:
        if written >= 10:
            print("sink: cap of 10 proposals reached, ignoring remainder")
            anomalies += 1
            break
        body = body_s.encode("utf-8")
        if not name_ok.match(fname):
            print("sink: rejected filename %r" % fname)
            anomalies += 1
            continue
        if len(body) > 65536:
            print("sink: rejected oversized body for %s" % fname)
            anomalies += 1
            continue
        # O_EXCL: atomic create-or-skip, no exists()/write TOCTOU window;
        # 0600 because content is model output shaped by untrusted
        # transcript material.
        try:
            fd = os.open(
                dest / fname,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
        except FileExistsError:
            print("sink: skipped existing %s" % fname)
            continue
        with os.fdopen(fd, "wb") as f:
            f.write(body)
        written += 1
        print("sink: wrote %s" % fname)
    print("sink: done, %d proposal(s) written" % written)
    if anomalies:
        print("sink: %d anomaly(ies) — raw output worth keeping" % anomalies)
        sys.exit(2)
  '';

  rsiDailyReview = pkgs.writeShellApplication {
    name = "rsi-daily-review";
    runtimeInputs = [ rsiProposalSink pkgs.coreutils pkgs.jq ];
    text = ''
      prompt_file="$HOME/.claude/recursive-self-improvement/config/prompt.md"
      dest="$HOME/.claude/recursive-self-improvement/proposals"
      config_file="$HOME/.claude/recursive-self-improvement/config/config.json"
      # Component gate, and it runs FIRST — before the claude lookup, before
      # the prompt read, before anything that could fail for an unrelated
      # reason. RSI's parts are switched individually from config.json
      # (components.daily_review / auto_research / permission_ledger), so
      # pausing the nightly reviewer is a one-key JSON edit rather than a
      # crontab PR — which is the whole reason the cron line below is live
      # again after the 2026-08-02 usage-cap disable.
      #
      # Absent config, absent key or unparseable JSON all read as OFF here.
      # This run is a headless Opus pass over the whole transcript corpus and
      # its cost has never been measured; a config fault must not start it.
      # The permission-ledger evaluator defaults the opposite way (absent =
      # on) because it is cheap and it is the only stage that surfaces the
      # permission ledger to a human. Expensive fails off, cheap fails on.
      #
      # The identity test lives INSIDE jq, and jq's exit status is the gate.
      # It must not be a shell string comparison against a `jq -r` render:
      # `-r` prints the JSON string "true" as the bare text `true`, exactly
      # as it prints boolean true, so `[ "$enabled" = true ]` accepted a
      # config typo of "daily_review": "true" and started the spend. Every
      # other shape already failed shut, so the string was the whole hole.
      # `jq -e` exits 1 when the expression yields false or null and 5 on
      # malformed input; with `[ -r ]` in front, an unreadable or missing
      # file never reaches jq. Boolean true is the only ON.
      if ! [ -r "$config_file" ] \
        || ! jq -e '.components.daily_review == true' "$config_file" >/dev/null 2>&1; then
        echo "rsi-daily-review: components.daily_review is not boolean true in $config_file — skipping (no model call)"
        exit 0
      fi
      # claude is deliberately NOT in runtimeInputs (it lives in the user
      # profile and updates independently); fail loudly if the cron PATH
      # doesn't resolve it rather than dying cryptically mid-pipeline.
      command -v claude >/dev/null 2>&1 || {
        echo "rsi-daily-review: claude not resolvable on PATH" >&2
        exit 127
      }
      if [ ! -r "$prompt_file" ]; then
        echo "rsi-daily-review: prompt file missing/unreadable: $prompt_file" >&2
        exit 1
      fi
      psize="$(stat -c%s "$prompt_file")"
      if [ "$psize" -gt 102400 ]; then
        echo "rsi-daily-review: $prompt_file is ''${psize}B (>100KiB cap); refusing (ARG_MAX)" >&2
        exit 1
      fi
      # Derive XDG_RUNTIME_DIR up front (cron doesn't set it): mktemp
      # below and the bus check both depend on it — deriving it late
      # would silently send mktemp to /tmp on every cron run.
      export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
      # Raw model output derives from untrusted transcript content — keep
      # it in the per-user tmpfs when available rather than world-listable
      # /tmp (mktemp still gives 0600 either way).
      tmpdir="/tmp"
      [ -d "$XDG_RUNTIME_DIR" ] && tmpdir="$XDG_RUNTIME_DIR"
      raw="$(mktemp -p "$tmpdir" rsi-daily-review.XXXXXX)"
      trap 'rm -f "$raw"' EXIT
      override="

      ## Headless run override (appended by the rsi-daily-review wrapper)

      You are running non-interactively with READ-ONLY tools. Do not
      attempt Write, Edit or Bash — they are not granted, and file
      writes under ~/.claude are blocked in --print mode anyway.
      Instead of writing proposal files in Step 4, emit each proposal
      on stdout as:

      ===PROPOSAL: YYYY-MM-DD-<slug>.md===
      <full proposal file body, frontmatter included>
      ===END PROPOSAL===

      The delimiters must start at column one. Skip Step 5 (push)
      entirely: a trusted wrapper persists these blocks to the
      proposals directory, and pushing happens behind the proposals
      intake gate."
      echo "rsi-daily-review: start $(date -Is)"
      # Memory-bound the model call when the user bus is reachable (same
      # per-call cgroup pattern research-agent uses, commit 48447eb
      # there). If the bus socket is absent (nobody logged in, no
      # lingering) run plain — an unbounded 03:20 run beats a dead one,
      # and the host now has swap+zram headroom.
      scope=()
      if [ -S "$XDG_RUNTIME_DIR/bus" ]; then
        scope=(systemd-run --user --scope --quiet -p MemoryMax=6G -p MemoryHigh=4G)
      else
        echo "rsi-daily-review: no user bus; running without MemoryMax scope" >&2
      fi
      rc=0
      "''${scope[@]}" timeout "''${RSI_REVIEW_TIMEOUT:-3600}" \
        claude --model opus --print --allowedTools "Read Glob Grep" \
        -p "$(cat "$prompt_file")$override" > "$raw" || rc=$?
      if [ "$rc" -eq 124 ]; then
        echo "rsi-daily-review: claude timed out after ''${RSI_REVIEW_TIMEOUT:-3600}s" >&2
        exit "$rc"
      elif [ "$rc" -eq 137 ]; then
        echo "rsi-daily-review: killed rc=137 — likely MemoryMax OOM-kill in the scope" >&2
        exit "$rc"
      elif [ "$rc" -ne 0 ]; then
        # rc can also originate from systemd-run scope setup (203 exec
        # failure etc.), not only claude itself — keep both in view.
        echo "rsi-daily-review: claude (or scope setup) exited rc=$rc" >&2
        exit "$rc"
      fi
      sink_rc=0
      rsi-proposal-sink "$dest" < "$raw" || sink_rc=$?
      if [ "$sink_rc" -ne 0 ]; then
        keep="$HOME/.claude/logs/rsi-raw-failed-$(date +%Y%m%dT%H%M%S).txt"
        cp "$raw" "$keep" || echo "rsi-daily-review: could not preserve raw output to $keep" >&2
        if [ "$sink_rc" -eq 2 ]; then
          # Anomalies (rejects/truncation/missing-END) but the run itself
          # succeeded — keep forensics, don't fail the cron entry.
          echo "rsi-daily-review: sink reported anomalies; raw kept at $keep" >&2
        else
          echo "rsi-daily-review: sink failed rc=$sink_rc; raw kept at $keep" >&2
          exit "$sink_rc"
        fi
      fi
      echo "rsi-daily-review: done $(date -Is)"
    '';
  };
in
{
  imports = [
    ./jonathan.nix
    ./cinnamon.nix
    ./desktop-apps.nix
    ./calibre-plugins.nix
    ./ghostty.nix
    ./kitty.nix
    ./git-hooks.nix
    ./autodoro.nix
    ./claude-mcp-sync.nix
    ./dcg.nix
    ./drift-analyzer.nix
    ./sota-watch.nix
    ./worktree-sweep.nix
    ./router-services.nix
    ./claude-services.nix
    ./claude-skills.nix
    ./research-agent-mcp.nix
    ./futuresearch-gate-mcp.nix
    # Must stay AFTER ./jonathan.nix: it redefines claude()/claudee()
    # through `programs.zsh.initContent = lib.mkAfter`, and the later
    # definition is the one the shell keeps.
    ./claude-egress-slice.nix
  ];

  # Point Gemini-aware tools at the agenix-decrypted key path. Consumers
  # (prose-decorate --audio, future Gemini tools) read this env var and
  # do `Path($GEMINI_API_KEY_FILE).read_text().strip()` — wrapping with
  # writeShellApplication is unnecessary because home.sessionVariables
  # reach interactive shells (which is where prose-decorate runs).
  home.sessionVariables.GEMINI_API_KEY_FILE = "/run/agenix/gemini-api-key";

  # User crontab — declarative source of truth. Re-applied on every rebuild
  # (overwrites any ad-hoc `crontab -e` edits).
  # Several cron entries redirect into ~/.claude/logs/ before their
  # command runs; the shell opens the redirect target first, so a
  # missing directory kills the whole entry silently. mkdir via
  # activation rather than a home.file .keep: ~/.claude is a user git
  # repo and logs/ is not gitignored there, so a store symlink would
  # pollute its git status — and HM aborts activation outright if a
  # regular file already sits at the .keep path.
  home.activation.ensureClaudeLogsDir = lib.hm.dag.entryAfter ["writeBoundary"] ''
    mkdir -p "$HOME/.claude/logs"
  '';

  home.file.".config/crontab".text = ''
    CRON_TZ=Europe/Stockholm
    PATH=${cronPath}
    0 9 * * 1 /home/jonathan/.claude/date-check.sh
    0 10 * * 1 /home/jonathan/.claude/scripts/update-submodules.sh >> /home/jonathan/.claude/logs/submodule-update.log 2>&1
    0 11 * * 1 /home/jonathan/Repos/dotfiles/backup-crontab.sh >> /home/jonathan/Repos/dotfiles/backup-crontab.log 2>&1
    23 14 * * * /home/jonathan/Repos/dotfiles/sync-agent.sh >> /home/jonathan/Repos/dotfiles/sync.log 2>&1
    0 10 * * * /home/jonathan/Repos/nixos-config/scripts/mint-drift-agent.sh >> /home/jonathan/.local/share/mint-drift-analyzer/run.log 2>&1
    0 10 * * 1 git -C /home/jonathan/Repos/everything-claude-code pull --ff-only >> /home/jonathan/.claude/logs/ecc-pull.log 2>&1
    0 9 * * 1 touch /home/jonathan/.claude/homunculus/.evolve-reminder
    0 */6 * * * /home/jonathan/.claude/repo-autosync-data/token-optimizer/wrapper.sh
    */30 6-22 * * * ${wellbeingPython}/bin/python3 /home/jonathan/.claude/wellbeing/habit-tracker.py >> /home/jonathan/.claude/logs/habit-tracker.log 2>&1
    */30 * * * * ${wellbeingPython}/bin/python3 /home/jonathan/.claude/wellbeing/sunset-walk-tracker.py >> /home/jonathan/.claude/logs/sunset-walk-tracker.log 2>&1
    # superpowers is a PUBLIC fork of obra/superpowers and gitignores
    # sync-agent.sh on purpose — local automation must not land in the
    # tree or leak into an upstream PR. The previous line pointed at an
    # in-repo copy that consequently did not exist, so every run since
    # logged `No such file or directory` and synced nothing. The canonical
    # script now takes a SYNC_REPO override so it can sync a repo it does
    # not live inside; nothing needs to exist in the public tree.
    37 15 * * * SYNC_REPO=/home/jonathan/Repos/superpowers /home/jonathan/.claude/skills/repo-autosync/sync-agent.sh >> /home/jonathan/Repos/superpowers/sync.log 2>&1
    11 16 * * * /home/jonathan/Repos/aggregator/sync-agent.sh >> /home/jonathan/Repos/aggregator/sync.log 2>&1
    # ~/.claude auto-commit + push. Declared here rather than via
    # `crontab -` because installCrontab rewrites the live crontab on
    # every rebuild — the same trap that killed the RSI reviewer for four
    # months and swallowed the permission-ledger entry.
    47 13 * * * /home/jonathan/.claude/sync-agent.sh >> /home/jonathan/.claude/sync.log 2>&1
    # Recursive Self-Improvement daily reviewer. The plugin's install.sh
    # tries to install this via `crontab -e`, which loses on every
    # nixos-rebuild switch (activation hook `installCrontab` below
    # rewrites the crontab from this file's rendered content) and every
    # Monday 11:00 via backup-crontab.sh capturing whatever's live.
    # Consequence: the RSI analysis job stopped firing 2026-04-17 — the
    # day a rebuild landed after the plugin was configured — and there
    # was no reviewer output for four months until this entry landed.
    # Declaring the schedule here is the only durable path on dellan.
    #
    # 03:20 slot is deliberately off-peak (no other cron entries between
    # 00:00-06:00 except the */30 pulls) so the headless `claude --print`
    # subagent doesn't contend with wellbeing trackers or backups. The
    # reviewer prompt itself is still known-broken (produces
    # duplicate-of-shipped-work proposals per empirical 2026-08-01 03am
    # runs) — the human reviews the output via /review-improvements
    # before anything auto-lands, so daily cadence is safe until the
    # grep-gate / scorer-gate fixes ship in a separate PR.
    #
    # The entry does NOT mirror the plugin's install.sh line — that line
    # was broken-by-construction headless (path-scoped Write grants
    # don't register via --allowedTools, and ~/.claude is behind Claude
    # Code's sensitive-path gate; both probed 2026-08-01). See the
    # rsiDailyReview comment in the let-block above: read-only model,
    # stdout proposal blocks, trusted sink persists.
    #
    # Disabled 2026-08-02 by commenting this line out (usage cap: a
    # nightly headless Opus pass over the whole transcript corpus, cost
    # never measured). Re-enabled 2026-08-03 as a LIVE line whose work
    # is gated at runtime instead: the wrapper reads
    # components.daily_review from
    # ~/.claude/recursive-self-improvement/config/config.json and exits
    # before spending anything unless it is exactly true. It currently
    # is false, so this entry fires nightly and no-ops in milliseconds.
    # The switch moved out of the crontab on purpose — flipping RSI's
    # parts individually is now a JSON edit, not a PR + rebuild + deploy
    # cycle, and the entry can no longer rot silently in a comment the
    # way the 2026-04-17..08-01 outage did.
    20 3 * * * ${rsiDailyReview}/bin/rsi-daily-review >> /home/jonathan/.claude/logs/review-agent.log 2>&1 # recursive-self-improvement-analysis
    # Permission-ledger nightly evaluator (shipped 2026-08-01 by a
    # separate session into ~/.claude/permission-ledger/). Its installer
    # wrote this entry into the LIVE crontab only — same trap as the RSI
    # line above: the installCrontab activation hook rewrites the live
    # crontab from this file on every rebuild, so without this line the
    # first deploy after 2026-08-01 silently kills the evaluator.
    # Line copied verbatim from the live crontab entry the installer
    # created (verified accepted by cron), tag comment included so the
    # installer's idempotency check recognises it as already present.
    30 17 * * * $HOME/.claude/permission-ledger/run-evaluate.sh >> $HOME/.claude/logs/permission-ledger.log 2>&1 # permission-ledger-evaluate
    # Keep the bare nixos-config repo's local `main` ref in sync with
    # origin/main so new worktrees (`git worktree add ... main`) don't
    # start behind. Bare repo = no working tree, no conflicts possible;
    # `main:main` refspec advances the ref in-place.
    # NOT `git -C ~/Repos/nixos-config fetch origin main:main`: that form
    # died every run with "refusing to fetch into branch 'main' checked
    # out at .../nixos-config-worktrees/main" — git will not move a ref
    # that a worktree has checked out. It failed silently into the log
    # from the day the `main` browse worktree was created until
    # 2026-07-31, by which point local `main` sat at PR #79, 99 files
    # behind origin/main, and every `git worktree add ... main` started
    # a hundred files in the past. Fast-forwarding through the worktree
    # that holds the ref is the form that actually works; --ff-only
    # keeps it a no-op-or-advance on a browse-only checkout.
    */30 * * * * git -C /home/jonathan/Repos/nixos-config-worktrees/main pull --ff-only origin main >> /home/jonathan/.claude/logs/nixos-config-fetch.log 2>&1
    # Keep the research-agent working copy current. That checkout IS
    # production twice over: research-agent-mcp runs it directly
    # (`uv run --project ~/Repos/research-agent`), and the research
    # microvm bind-mounts the same directory read-only at /workspace, so
    # the jailed agent reads run-agent.sh, the shims and its CLAUDE.md
    # fresh from it on every call. An unpulled merge therefore ships
    # stale code to every newly spawned server and every research call.
    # 2026-07-29..31: a merged model-fallback fix (PR #19) sat unpulled
    # for three days while every research call failed 429 — MCP
    # processes churned constantly, the checkout never moved, and two
    # agent sessions misread it as "the research backend is down".
    # Pull rather than fetch (unlike the bare repo above, this one has a
    # working tree that must actually advance); --ff-only so a dirty or
    # diverged tree fails loudly into the log instead of fabricating a
    # merge commit on a live production path.
    */30 * * * * git -C /home/jonathan/Repos/research-agent pull --ff-only >> /home/jonathan/.claude/logs/research-agent-pull.log 2>&1
  '';

  # `crontab` is a setuid wrapper at /run/wrappers/bin/crontab (provided by
  # services.cron.enable). Home-manager activation runs with a minimal PATH
  # that doesn't include /run/wrappers/bin, so `command -v crontab` returned
  # nothing here and the if-guard silently skipped the reinstall — leaving
  # the active crontab stale after every `nixos-rebuild switch`. The
  # backup-sync agent (~/Repos/dotfiles/sync-agent.sh, scheduled daily)
  # didn't compensate either, because it bails out without gitleaks.
  # Result: cron entries on disk drifted from the active crontab for days
  # (caught when wellbeing trackers kept failing with /usr/bin/python3
  # after the python-path fix had already deployed).
  #
  # Ordering: entryAfter ["linkGeneration"], NOT ["writeBoundary"]. The
  # writeBoundary marker fires before the new generation's symlinks
  # under $HOME are swapped in; the symlink at $HOME/.config/crontab
  # still points at the PREVIOUS generation's store path during any
  # activation hook running between writeBoundary and linkGeneration.
  # An earlier iteration of this hook reinstalled the OLD content on
  # every rebuild, which is how PR #52's PATH= addition didn't reach
  # the active crontab even after a successful deploy. linkGeneration
  # is the step that updates the symlinks; running after it guarantees
  # crontab reads the new generation.
  home.activation.installCrontab = lib.hm.dag.entryAfter ["linkGeneration"] ''
    if [ -x /run/wrappers/bin/crontab ]; then
      /run/wrappers/bin/crontab "$HOME/.config/crontab" || true
    fi
  '';

  # router-agent expects ~/.config/router/paths.yaml. Project is cloned
  # by cloneRepos activation but its config dir lives outside the repo.
  # Content migrated 1:1 from the prior Mint install (mint-backup-2026-05-05).
  # Contains no secrets — just Dropbox roots and local-state directory
  # paths.
  home.file.".config/router/paths.yaml".text = ''
    version: 1

    # Dropbox roots — sync target for ingestion and exocortex artifacts.
    # Change ~/Dropbox to wherever your Dropbox folder lives.
    dropbox_root: ~/Dropbox
    inlet_transcripts: ''${dropbox_root}/1. Exocortex/_Inlet/Android/Transcripts
    exocortex_root: ''${dropbox_root}/1. Exocortex

    # Local-disk roots (per-machine, never in Dropbox).
    state_root: ~/.local/state/router
    inbox_root: ''${state_root}/inbox
    processed_root: ''${state_root}/processed
    queue_root: ''${state_root}/queue
    audit_root: ''${state_root}/audit
    ingestor_ledger: ''${state_root}/ingestor-ledger.db
  '';

  # Clone user repos into ~/Repos on first activation.
  #
  # Strategy: try SSH first (works for both public + private once the host's
  # SSH key is added at https://github.com/settings/keys), fall back to
  # HTTPS (works for public repos only). All clones are best-effort —
  # failures are silent so a missing key/network doesn't block rebuild.
  #
  # Re-running activation (every nixos-rebuild switch) is a no-op for any
  # repo that already exists. Update existing repos via the cron-driven
  # repo-autosync agent or `git pull` manually.
  #
  # ~/.claude is intentionally NOT auto-cloned: claude-code populates
  # ~/.claude with runtime state (backups/, projects/, sessions/, cache/)
  # on first run, and the .claude *repo* needs to coexist with that state.
  # On a fresh host: move runtime dirs aside, `git clone
  # git@github.com:jonathanmoregard/.claude.git ~/.claude`, restore
  # runtime dirs, `git submodule update --init --recursive`.
  #
  # As of home/dcg.nix, `dcg.toml` is also in the "move aside" set: this
  # module's ensureClaudeLogsDir already makes ~/.claude non-empty before
  # any clone, and home/dcg.nix additionally seeds ~/.claude/dcg.toml
  # with a bootstrap fallback when it is absent — because a missing
  # target there does not merely lose a file, it silently disarms the
  # whole dcg user layer. Move it aside with the rest, clone, then let
  # the repo's own dcg.toml win.
  home.activation.cloneRepos = lib.hm.dag.entryAfter ["writeBoundary"] ''
    mkdir -p "$HOME/Repos"
    mkdir -p "$HOME/.local/share"

    clone_if_missing() {
      local repo="$1"
      local dir="$2"
      if [ ! -d "$dir" ]; then
        GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="" SSH_ASKPASS="" \
          ${pkgs.git}/bin/git clone "git@github.com:jonathanmoregard/$repo.git" "$dir" 2>/dev/null \
        || GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="" SSH_ASKPASS="" \
             ${pkgs.git}/bin/git clone "https://github.com/jonathanmoregard/$repo.git" "$dir" 2>/dev/null \
        || true
      fi
    }

    # router-agent lives outside ~/Repos because router-services.nix
    # configures the systemd units' WorkingDirectory to
    # %h/.local/share/router-agent (uv-managed venv lands alongside).
    # uv will bootstrap the venv on first `uv run`; if resolution fails
    # the unit goes into Restart=on-failure (journal-visible, not
    # silent).
    clone_if_missing router-agent "$HOME/.local/share/router-agent"

    clone_if_missing autodoro "$HOME/Repos/autodoro"
    clone_if_missing intender "$HOME/Repos/intender"
    clone_if_missing weekend "$HOME/Repos/weekend"
    clone_if_missing nixos-config "$HOME/Repos/nixos-config"
    clone_if_missing artcraft "$HOME/Repos/artcraft"
    clone_if_missing claude-code "$HOME/Repos/claude-code"
    clone_if_missing claude-exam "$HOME/Repos/claude-exam"
    clone_if_missing jhana "$HOME/Repos/jhana"
    clone_if_missing jonathan-claude-marketplace "$HOME/Repos/jonathan-claude-marketplace"
    clone_if_missing survival-corpus "$HOME/Repos/survival-corpus"
    clone_if_missing superpowers "$HOME/Repos/superpowers"
    clone_if_missing voquill "$HOME/Repos/voquill"
    clone_if_missing dotfiles "$HOME/Repos/dotfiles"
    clone_if_missing everything-claude-code "$HOME/Repos/everything-claude-code"
  '';
}
