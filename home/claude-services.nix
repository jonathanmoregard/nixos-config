{ config, pkgs, ... }:
# Claude-related user services. Captured from live host on 2026-04-27 — these
# units were installed imperatively (~/.config/systemd/user/) and would be
# lost on a fresh rebuild without this declarative copy.
#
# All three depend on supporting state under ~/.claude (dev-container venv,
# GitHub App private key, homunculus, container-staging). On a fresh install
# the units will fail at first tick until that scaffolding is set up
# separately.
let
  # Lakera Guard tuned-policy pointer, single-sourced in home/lakera.nix
  # (shared with research-agent-mcp.nix and futuresearch-gate-mcp.nix).
  lakera = import ./lakera.nix;

  # claude-cl-sync's injection-scanner probes Anthropic + OpenAI (L3
  # honeypot) and Lakera Guard (L2 classifier) on every tick. systemd's
  # `EnvironmentFile=` expects KEY=VALUE format, but our agenix `.age`
  # files contain the raw key value only (no `ANTHROPIC_API_KEY=` prefix).
  # Read the raw bytes with `$(< file)` (strips trailing newline) and
  # export before execing the real entry. LAKERA is fail-closed in the
  # scanner — without it the scan rejects, so it must be a real key.
  claude-cl-sync-wrap = pkgs.writeShellApplication {
    name = "claude-cl-sync-wrap";
    text = ''
      ANTHROPIC_API_KEY=$(< /run/agenix/anthropic-api-key)
      OPENAI_API_KEY=$(< /run/agenix/openai-api-key)
      LAKERA_API_KEY=$(< /run/agenix/lakera-api-key)
      # The scanner's Lakera call uses stdlib urllib, which finds no CA
      # bundle on NixOS in a non-nix CPython — cert verify fails
      # (lakera_unavailable:URLError) and the fail-closed scan rejects.
      # Full rationale in research-agent-mcp.nix.
      SSL_CERT_FILE="''${SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}"
      export ANTHROPIC_API_KEY OPENAI_API_KEY LAKERA_API_KEY SSL_CERT_FILE
      # Lakera Guard tuned-policy project (not a secret — see
      # home/lakera.nix). injection_scanner/lakera.py sends
      # payload["project_id"] when this is set, selecting the tuned
      # L3 project policy instead of the account default.
      export LAKERA_PROJECT_ID=${lakera.lakeraProjectId}
      exec "$HOME/.claude/dev-container/.venv/bin/python3" \
           "$HOME/.claude/dev-container/bin/claude-cl-sync"
    '';
  };
in
{
  # claude-cl-sync — vet container-captured CL-v2 observations and merge to
  # host homunculus. Pulls latest scanner from origin/main on every tick.
  systemd.user.services.claude-cl-sync = {
    Unit = {
      Description = "Vet container-captured CL-v2 observations and merge to host homunculus";
      After = [ "default.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.uv}/bin/uv pip install --python %h/.claude/dev-container/.venv/bin/python3 --no-cache --quiet --upgrade --force-reinstall injection-scanner@git+https://github.com/jonathanmoregard/injection-scanner@main";
      # Wrapper reads agenix raw-key files and exports ANTHROPIC_API_KEY
      # + OPENAI_API_KEY before execing the real cl-sync entry. Needed
      # because `.age` files contain raw key values (no `KEY=` prefix),
      # so systemd's `EnvironmentFile=` can't parse them.
      ExecStart = "${claude-cl-sync-wrap}/bin/claude-cl-sync-wrap";
      Nice = 10;
      Environment = "PYTHONDONTWRITEBYTECODE=1";

      # Hardening
      NoNewPrivileges = "yes";
      PrivateTmp = "yes";
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = "%h/.claude/homunculus %h/.claude/container-staging %h/.claude/dev-container/.venv";
      ProtectKernelTunables = "yes";
      ProtectKernelModules = "yes";
      ProtectControlGroups = "yes";
      RestrictSUIDSGID = "yes";
      LockPersonality = "yes";
      MemoryMax = "1G";
      TasksMax = 256;
    };
  };

  systemd.user.timers.claude-cl-sync = {
    Unit.Description = "Run claude-cl-sync every 6h";
    Timer = {
      OnBootSec = "5min";
      OnUnitActiveSec = "6h";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # gh-token — rotate GitHub App installation tokens for active sandboxes.
  systemd.user.services.gh-token = {
    Unit.Description = "Rotate GitHub App installation tokens for active Claude sandboxes";
    Service = {
      Type = "oneshot";
      ExecStart = "%h/.claude/dev-container/bin/mint-gh-token";
      Nice = 5;

      NoNewPrivileges = "yes";
      PrivateTmp = "yes";
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = "%h/.cache/gh-tokens";
      ReadOnlyPaths = "%h/.config/github-app/app.pem";
      ProtectKernelTunables = "yes";
      ProtectKernelModules = "yes";
      ProtectControlGroups = "yes";
      RestrictSUIDSGID = "yes";
      LockPersonality = "yes";
      MemoryMax = "128M";
      TasksMax = 32;
    };
  };

  systemd.user.timers.gh-token = {
    Unit.Description = "Rotate GitHub App tokens every 50 minutes";
    Timer = {
      OnBootSec = "1min";
      OnUnitActiveSec = "50min";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # claude-idle-handoff — proactive mission.md writer + opus-5 autofork
  # for idle Claude Code sessions. Scans every 5 min for sessions that
  # have been silent long enough to be considered "walked away from"
  # and drops a mission.md handoff so the next session can pick up
  # without replaying the whole log.
  #
  # The SCRIPT itself lives at ~/.claude/scripts/idle-handoff.sh (with
  # a helper at ~/.claude/skills/session-reflect/reflect.sh in `mission`
  # mode). Both are tracked in the ~/.claude git repo separately, NOT
  # pinned into the nix store — the script iterates hot on its own
  # cadence and putting it under nix would force a rebuild for every
  # tweak. Only the TIMER + SERVICE are declared here, so a fresh
  # rebuild re-creates the schedule; the script is (like the rest of
  # ~/.claude) provisioned by its own sync path.
  #
  # Captured from live imperative units at
  # ~/.config/systemd/user/claude-idle-handoff.{service,timer} on
  # 2026-08-08 — same rationale as the file-level comment above.
  systemd.user.services.claude-idle-handoff = {
    Unit = {
      Description = "Claude Code idle handoff — proactive mission.md write for idle sessions";
      After = [ "default.target" ];
    };
    Service = {
      Type = "oneshot";
      # %h expands to $HOME under home-manager's systemd --user.
      ExecStart = "%h/.claude/scripts/idle-handoff.sh";
      # Scanner, not real work — stay out of interactive processes' way.
      Nice = 15;
      IOSchedulingClass = "idle";
      # reflect.sh may spawn a real claude call in mission mode; 3 min
      # is comfortably above p99 and well below the 5 min timer cadence
      # so a stuck run cannot pile up two invocations.
      TimeoutStartSec = 180;
    };
  };

  systemd.user.timers.claude-idle-handoff = {
    Unit.Description = "Run claude-idle-handoff every 5 minutes";
    Timer = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5min";
      # ±30s jitter keeps every 5-min tick from stampeding when several
      # user timers land on the same wall-clock boundary.
      AccuracySec = "30s";
      # Idle-scanner: catching up after a suspend would fire a stale
      # tick against sessions that are no longer idle — skip missed
      # runs and wait for the next natural boundary.
      Persistent = false;
      Unit = "claude-idle-handoff.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # claude-pull — the ONLY writer to ~/.claude, as of 2026-08-31.
  #
  # It began as the pull half of a push/pull pair: sync-agent.sh (cron,
  # 13:47) auto-committed and pushed, but nothing brought origin's
  # commits back down, so a PR merged in the GitHub UI never reached the
  # checkout that actually runs the config — skills, hooks and settings
  # sat at the last local commit until someone pulled by hand.
  #
  # The push half is now gone (see the crontab block in
  # home/jonathan-linux.nix for why). ~/.claude is read-only: work
  # happens in worktrees under ~/worktrees/claude-<slug> and reaches
  # master through a PR, and this timer is what brings it back down.
  # That makes fast-forward-only a load-bearing property rather than a
  # nicety — nothing local should ever diverge for it to reconcile.
  #
  # Same split as claude-idle-handoff above: the TIMER and SERVICE are
  # declared here so a fresh rebuild re-creates the schedule, while the
  # script lives in the ~/.claude repo (it iterates on that repo's own
  # cadence and pinning it into the store would force a rebuild per
  # tweak). The script is fast-forward-only by construction — unlike
  # /etc/nixos, ~/.claude is a live working tree that sessions write to,
  # so nixos-deploy's `git reset --hard` would destroy in-flight work.
  systemd.user.services.claude-pull = {
    Unit = {
      Description = "Fast-forward ~/.claude to origin (CD for the Claude config repo)";
      After = [ "default.target" ];
    };
    Service = {
      Type = "oneshot";
      # %h expands to $HOME under home-manager's systemd --user.
      ExecStart = "%h/.claude/scripts/claude-pull.sh";
      # Background maintenance — never compete with an interactive session.
      Nice = 10;
      IOSchedulingClass = "idle";
      # The script bounds its own fetch at 60s; this is the backstop for a
      # hang anywhere else in the run. Comfortably under the 10min cadence
      # so a wedged tick cannot overlap the next one.
      TimeoutStartSec = 180;
    };
  };

  systemd.user.timers.claude-pull = {
    Unit.Description = "Poll origin for merged ~/.claude PRs every 10 minutes";
    Timer = {
      # Calendar rather than monotonic (unlike its neighbours) precisely so
      # Persistent= applies: it has no effect on OnUnitActiveSec= timers.
      # This is a laptop that suspends, and a merge landing while it sleeps
      # should arrive on resume, not at the next natural boundary.
      OnCalendar = "*:0/10";
      Persistent = true;
      # Nothing downstream cares about the exact second; the slack lets
      # systemd coalesce this tick with other wakeups instead of waking the
      # machine on its own, and keeps it out of the on-the-minute stampede.
      AccuracySec = "1min";
      RandomizedDelaySec = "1min";
      Unit = "claude-pull.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # claude-marketplace-pull — the same puller, second target.
  #
  # ~/.claude/plugins/marketplaces/jonathanmoregard is an INDEPENDENT nested
  # git checkout: `plugins/` is gitignored in ~/.claude, so claude-pull above
  # never touched it however often it ran. It is also the tree the harness
  # actually resolves plugins from, which makes it going stale worse than
  # ~/.claude going stale — measured 2026-08-31 at 35 commits behind origin,
  # meaning every session in that window served skills, commands and agents
  # from an old tree while reporting success. Merged plugin work simply never
  # reached the running harness.
  #
  # A SIBLING UNIT, not a loop inside claude-pull.sh. The script is
  # `set -euo pipefail` and exits 1 on any state it will not resolve by force,
  # so a single unit iterating over both repos would let one target's problem
  # abort the other's pull — and systemd could no longer say which repo is red,
  # nor could `journalctl --user -u <unit>` separate them. Two units, two
  # failure domains, one implementation of the careful part: bounded fetch,
  # fast-forward-only, the lock shared with sync-agent.sh, alert debounce.
  # CLAUDE_PULL_REPO is the seam the script already exposes for exactly this.
  #
  # Fast-forward-only is load-bearing here for a reason ~/.claude does not
  # have: this clone deliberately carries a local dev overlay (an untracked
  # symlink to a live superpowers checkout). `git pull --ff-only` refuses when
  # local work is in the way and changes nothing, which is the correct outcome
  # — the overlay outranks an automated update. That refusal is REPORTED, never
  # forced: never a reset, never a stash. The report reaches a Claude session
  # through hooks/claude-pull-health.py in the ~/.claude repo, which reads the
  # status records this script writes; a desktop toast alone would leave every
  # session blind to it, which is the failure this whole pair of changes ends.
  systemd.user.services.claude-marketplace-pull = {
    Unit = {
      Description = "Fast-forward the Claude plugin marketplace clone to origin";
      After = [ "default.target" ];
    };
    Service = {
      Type = "oneshot";
      # %h expands to $HOME under home-manager's systemd --user.
      ExecStart = "%h/.claude/scripts/claude-pull.sh";
      # ABSOLUTE path, interpolated at build time, NOT "%h/...". systemd
      # expands specifiers in ExecStart= but NOT in Environment=. Measured on
      # this host before writing this line:
      #
      #   $ systemd-run --user --wait --pipe -p 'Environment=PROBE=%h/marker' \
      #         /bin/sh -c 'echo "EXPANDED: $PROBE"'
      #   EXPANDED: %h/marker
      #
      # Copying the ExecStart spelling here would hand the script a relative
      # path literally named "%h", it would pull a directory that does not
      # exist, and the marketplace clone would keep silently rotting — the
      # exact failure this unit exists to end, reintroduced by a specifier that
      # looks right. tests/base.nix asserts the absolute path AND the absence
      # of any surviving "%h" in this unit's environment block.
      Environment = [
        "CLAUDE_PULL_REPO=${config.home.homeDirectory}/.claude/plugins/marketplaces/jonathanmoregard"
      ];
      # Background maintenance — never compete with an interactive session.
      Nice = 10;
      IOSchedulingClass = "idle";
      # The script bounds its own fetch at 60s; this is the backstop for a
      # hang anywhere else in the run.
      TimeoutStartSec = 180;
    };
  };

  systemd.user.timers.claude-marketplace-pull = {
    Unit.Description = "Poll origin for merged marketplace PRs every 10 minutes";
    Timer = {
      # Same cadence as claude-pull and the same reason for OnCalendar over
      # OnUnitActiveSec (Persistent= only applies to calendar timers, and this
      # is a laptop that suspends). Offset five minutes so the two pullers do
      # not fetch GitHub in the same breath on every tick — they share no lock,
      # being different repos, so the stagger is about network and wakeups
      # rather than correctness.
      OnCalendar = "*:5/10";
      Persistent = true;
      AccuracySec = "1min";
      RandomizedDelaySec = "1min";
      Unit = "claude-marketplace-pull.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # claude-sandbox-proxy — hostname-allowlisted HTTP/HTTPS proxy for Claude
  # sandboxes. Long-running service, started at session login.
  systemd.user.services.claude-sandbox-proxy = {
    Unit = {
      Description = "Hostname-allowlisted HTTP/HTTPS proxy for Claude sandboxes";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "%h/.claude/dev-container/bin/claude-sandbox-proxy";
      Restart = "on-failure";
      RestartSec = 3;
      Environment = "PROXY_PORT=8888";

      NoNewPrivileges = "yes";
      PrivateTmp = "yes";
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadOnlyPaths = "%h/.claude/dev-container";
      ProtectKernelTunables = "yes";
      ProtectKernelModules = "yes";
      ProtectControlGroups = "yes";
      RestrictSUIDSGID = "yes";
      LockPersonality = "yes";
      MemoryMax = "256M";
      TasksMax = 512;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
