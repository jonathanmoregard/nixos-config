{ pkgs, ... }:
let
  # Shared with home/claude-codium-config.nix, which installs this same file
  # as the initial local.md. The probe below decides "has anything been
  # written here" by comparing against it, so a second copy of the text would
  # read as drift on every host the moment one copy was edited.
  codiumLocalSeed = ./claude-codium/local-seed.md;

  analyzerScript = pkgs.writeShellApplication {
    name = "nixos-drift-analyzer";
    runtimeInputs = with pkgs; [
      coreutils
      diffutils
      findutils
      gawk
      git
      gnugrep
      gnused
      nix
    ];
    text = ''
      set -euo pipefail

      nix_env_bin="''${NIXOS_DRIFT_NIX_ENV_BIN:-${pkgs.nix}/bin/nix-env}"
      deployed_config="''${NIXOS_DRIFT_DEPLOYED_CONFIG:-/etc/nixos}"
      declared_crontab="''${NIXOS_DRIFT_DECLARED_CRONTAB:-$HOME/.config/crontab}"
      crontab_bin="''${NIXOS_DRIFT_CRONTAB_BIN:-/run/wrappers/bin/crontab}"
      anchor="''${NIXOS_DRIFT_ANCHOR:-$HOME/Repos/nixos-config-worktrees/main}"
      report_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/nixos-drift-analyzer"
      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nixos-drift-analyzer"
      latest="$report_dir/latest.md"
      last_success="$state_dir/last-success"

      mkdir -p "$report_dir" "$state_dir"
      scratch=$(mktemp -d "$state_dir/.run.XXXXXX")
      report_tmp=$(mktemp "$report_dir/.latest.md.XXXXXX")
      success_tmp=$(mktemp "$state_dir/.last-success.XXXXXX")
      cleanup() {
        rm -rf "$scratch"
        rm -f "$report_tmp" "$success_tmp"
      }
      trap cleanup EXIT

      findings="$scratch/findings"
      : > "$findings"
      finding_count=0
      add_finding() {
        heading=$1
        details=$2
        finding_count=$((finding_count + 1))
        {
          printf '## %s\n\n' "$heading"
          printf '~~~text\n%s\n~~~\n\n' "$details"
        } >> "$findings"
      }

      # A failed probe is an analyzer failure, not a clean bill of health.
      # Keep last successful report and heartbeat untouched in that case.
      set +e
      imperative=$("$nix_env_bin" --query 2> "$scratch/nix-env.err")
      probe_status=$?
      set -e
      if [ "$probe_status" -ne 0 ]; then
        cat "$scratch/nix-env.err" >&2
        exit "$probe_status"
      fi
      if [ -n "$imperative" ]; then
        add_finding "Imperative nix-env packages" "$imperative"
      fi

      local_bin="$HOME/.local/bin"
      if [ -d "$local_bin" ]; then
        : > "$scratch/local-bin"
        find "$local_bin" -mindepth 1 -maxdepth 1 -print0 \
          | sort -z > "$scratch/local-bin-entries"
        while IFS= read -r -d $'\0' entry; do
          resolved=$(readlink -f "$entry" 2>/dev/null || printf '%s' "$entry")
          name=''${entry#"$local_bin"/}
          case "$resolved" in
            /nix/store/*) ;;
            # Claude Code's self-updating native installer is the binary
            # in use by design (home/claude-egress-slice.nix). Exempt only
            # that exact shape, so a hand-copied `claude` still reports.
            "$HOME"/.local/share/claude/versions/*)
              [ "$name" = claude ] \
                || printf '%s\n' "$name" >> "$scratch/local-bin" ;;
            *) printf '%s\n' "$name" >> "$scratch/local-bin" ;;
          esac
        done < "$scratch/local-bin-entries"
        if [ -s "$scratch/local-bin" ]; then
          add_finding \
            "Entries outside /nix/store in ~/.local/bin" \
            "$(cat "$scratch/local-bin")"
        fi
      fi

      # Home-manager writes every user unit, drop-in and *.wants entry as
      # a symlink pointing straight into /nix/store. Anything else here
      # was put there imperatively: a hand-authored unit file (lost on a
      # fresh install, 2026-08-08 claude-idle-handoff), a
      # `systemctl --user enable` link (targets the ~/.config path, not
      # the store), or a `systemctl --user edit` override file. The
      # immediate link target is checked, not the resolved one, because
      # an imperative enable of a declared unit resolves into the store
      # through the unit's own HM link.
      user_units="''${NIXOS_DRIFT_SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
      if [ -d "$user_units" ]; then
        : > "$scratch/user-units"
        find "$user_units" -mindepth 1 ! -type d -print0 \
          | sort -z > "$scratch/user-unit-entries"
        while IFS= read -r -d $'\0' entry; do
          target=$(readlink "$entry" 2>/dev/null || true)
          case "$target" in
            /nix/store/*) ;;
            *) printf '%s\n' "''${entry#"$user_units"/}" >> "$scratch/user-units" ;;
          esac
        done < "$scratch/user-unit-entries"
        if [ -s "$scratch/user-units" ]; then
          add_finding \
            "Unmanaged entries in ~/.config/systemd/user" \
            "$(cat "$scratch/user-units")"
        fi
      fi

      if git -c safe.directory="$deployed_config" -C "$deployed_config" \
        rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        set +e
        deployed_status=$(git -c safe.directory="$deployed_config" \
          -C "$deployed_config" status --porcelain --untracked-files=all \
          2> "$scratch/deployed-git.err")
        probe_status=$?
        set -e
        if [ "$probe_status" -ne 0 ]; then
          cat "$scratch/deployed-git.err" >&2
          exit "$probe_status"
        fi
        if [ -n "$deployed_status" ]; then
          add_finding "Deployed NixOS checkout has changes" "$deployed_status"
        fi
      else
        add_finding \
          "Deployed NixOS checkout is not a Git worktree" \
          "$deployed_config"
      fi

      if [ ! -f "$declared_crontab" ]; then
        add_finding "Declarative crontab is missing" "$declared_crontab"
      elif [ ! -x "$crontab_bin" ]; then
        add_finding "crontab command is unavailable" "$crontab_bin"
      else
        set +e
        "$crontab_bin" -l > "$scratch/crontab-live" 2> "$scratch/crontab.err"
        probe_status=$?
        set -e
        if [ "$probe_status" -ne 0 ]; then
          crontab_error=$(cat "$scratch/crontab.err")
          add_finding \
            "Installed crontab is unavailable" \
            "''${crontab_error:-crontab -l exited $probe_status}"
        else
          sed -E \
            -e '/^# DO NOT EDIT THIS FILE - edit the master and reinstall\.$/d' \
            -e '/^# \(.* installed on .*\)$/d' \
            -e '/^# \(Cron version .*\)$/d' \
            "$scratch/crontab-live" > "$scratch/crontab-normalized"
          if ! cmp -s "$declared_crontab" "$scratch/crontab-normalized"; then
            add_finding \
              "Installed crontab differs from declaration" \
              "declared: $declared_crontab
installed: crontab -l"
          fi
        fi
      fi

      if git -c safe.directory="$anchor" -C "$anchor" \
        rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        set +e
        git -c safe.directory="$anchor" -C "$anchor" worktree list --porcelain \
          > "$scratch/worktrees" 2> "$scratch/worktrees.err"
        probe_status=$?
        set -e
        if [ "$probe_status" -ne 0 ]; then
          cat "$scratch/worktrees.err" >&2
          exit "$probe_status"
        fi
        main_worktrees=$(grep -c '^branch refs/heads/main$' "$scratch/worktrees" || true)
        if [ "$main_worktrees" -gt 1 ]; then
          main_paths=$(awk '
            /^worktree / { path = substr($0, 10) }
            /^branch refs\/heads\/main$/ { print path }
          ' "$scratch/worktrees")
          add_finding \
            "Multiple worktrees share refs/heads/main" \
            "$main_paths"
        fi
      else
        add_finding "NixOS config anchor is unavailable" "$anchor"
      fi

      # The Codium Claude config directory (home/claude-codium-config.nix) is
      # a deliberately WRITABLE declared surface, so it drifts in a way the
      # probes above cannot see: a skill written straight into it works
      # immediately and survives every deploy, which makes it
      # indistinguishable from declared config right up until a fresh install
      # drops it. Nothing else looks in there, so without this a skill sits in
      # the live layer indefinitely and nobody is reminded it was never
      # reviewed.
      #
      # Managed entries are symlinks, and exactly two targets are managed: the
      # store (a skill declared in home/claude-codium/skills) and
      # ~/.claude/skills (one inherited from the shared config). Anything else
      # — a real directory, or a symlink into one of the user's own repos — is
      # the promotion queue. The immediate target is checked, not the resolved
      # one, for the same reason as the systemd/user probe above: an inherited
      # skill that is itself a store symlink resolves into the store without
      # being declared HERE.
      codium_dir="''${NIXOS_DRIFT_CODIUM_DIR:-''${XDG_STATE_HOME:-$HOME/.local/state}/claude-codium}"
      codium_seed="''${NIXOS_DRIFT_CODIUM_SEED:-${codiumLocalSeed}}"
      codium_shared="''${NIXOS_DRIFT_CODIUM_SHARED:-$HOME/.claude/skills}"
      if [ -d "$codium_dir/skills" ]; then
        : > "$scratch/codium-skills"
        : > "$scratch/codium-shadow"
        find "$codium_dir/skills" -mindepth 1 -maxdepth 1 -print0 \
          | sort -z > "$scratch/codium-entries"
        while IFS= read -r -d $'\0' entry; do
          name=''${entry#"$codium_dir"/skills/}
          target=$(readlink "$entry" 2>/dev/null || true)
          case "$target" in
            /nix/store/*) continue ;;
            "$codium_shared"/*) continue ;;
          esac
          printf '%s\n' "$name" >> "$scratch/codium-skills"
          # A live skill with the same name as a shared one WINS, silently:
          # activation leaves a real directory alone rather than relinking
          # over it. That is the skills-side equivalent of a declared
          # settings key being overridden, and this is the only place it is
          # ever stated.
          if [ -e "$codium_shared/$name" ]; then
            printf '%s\n' "$name" >> "$scratch/codium-shadow"
          fi
        done < "$scratch/codium-entries"
        if [ -s "$scratch/codium-skills" ]; then
          add_finding \
            "Codium-only skills live but not declared" \
            "$(cat "$scratch/codium-skills")"
        fi
        if [ -s "$scratch/codium-shadow" ]; then
          add_finding \
            "Codium skills shadowing a shared skill of the same name" \
            "$(cat "$scratch/codium-shadow")"
        fi
      fi

      # local.md is the prose half of the same layer: seeded once, the user's
      # from then on. Compared against the seed rather than checked for
      # existence, because the seed IS the empty state — byte-identical means
      # nothing has been written there yet.
      if [ -f "$codium_dir/local.md" ] && [ -f "$codium_seed" ] \
        && ! cmp -s "$codium_dir/local.md" "$codium_seed"; then
        add_finding \
          "Codium session notes live but not declared" \
          "$codium_dir/local.md"
      fi

      {
        printf '# NixOS drift report\n\n'
        printf 'Generated: %s\n\n' "$(date -Iseconds)"
        if [ "$finding_count" -eq 0 ]; then
          printf '## No drift detected\n'
        else
          printf '%s finding(s) need review.\n\n' "$finding_count"
          cat "$findings"
        fi
      } > "$report_tmp"
      printf 'timestamp=%s\nfindings=%s\n' \
        "$(date -Iseconds)" "$finding_count" > "$success_tmp"

      mv -f "$report_tmp" "$latest"
      mv -f "$success_tmp" "$last_success"
      printf 'NixOS drift analyzer completed: %s finding(s); report: %s\n' \
        "$finding_count" "$latest"
    '';
  };

  failureNotifyScript = pkgs.writeShellApplication {
    name = "nixos-drift-analyzer-failure-notify";
    runtimeInputs = [ pkgs.libnotify ];
    text = ''
      message="NixOS drift analyzer failed — inspect: journalctl --user -u nixos-drift-analyzer.service"
      printf '%s\n' "$message"
      notify-send --urgency=critical "NixOS drift analyzer failed" "$message" || true
    '';
  };
in
{
  home.packages = [ analyzerScript ];

  systemd.user.services = {
    nixos-drift-analyzer = {
      Unit = {
        Description = "Detect undeclared NixOS state drift";
        OnFailure = [ "nixos-drift-analyzer-failure-notify.service" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${analyzerScript}/bin/nixos-drift-analyzer";
        TimeoutStartSec = 120;
      };
    };

    nixos-drift-analyzer-failure-notify = {
      Unit.Description = "Notify when NixOS drift analysis fails";
      Service = {
        Type = "oneshot";
        ExecStart = "${failureNotifyScript}/bin/nixos-drift-analyzer-failure-notify";
      };
    };
  };

  systemd.user.timers.nixos-drift-analyzer = {
    Unit.Description = "NixOS drift analyzer — hourly";
    Timer = {
      OnCalendar = "hourly";
      AccuracySec = "5min";
      RandomizedDelaySec = "5min";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
