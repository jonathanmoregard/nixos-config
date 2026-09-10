{ lib, pkgs, ... }:
let
  renderInNamespace = pkgs.writeShellScript "ai-client-config-render-isolated" ''
    set -euo pipefail
    source_home="$1"
    staged_home="$2"
    repo="$3"
    sandbox_repo=/tmp/ai-client-config-repo
    sandbox_claude=/tmp/ai-client-config-claude
    sandbox_claude_state=/tmp/ai-client-config-claude.json

    mkdir -p "$sandbox_repo" "$sandbox_claude"
    ${pkgs.util-linux}/bin/mount --bind "$repo" "$sandbox_repo"
    ${pkgs.util-linux}/bin/mount --bind "$source_home/.claude" "$sandbox_claude"
    ${pkgs.util-linux}/bin/mount -o remount,bind,ro "$sandbox_claude"

    has_claude_state=0
    if [ -f "$source_home/.claude.json" ]; then
      touch "$sandbox_claude_state"
      ${pkgs.util-linux}/bin/mount --bind \
        "$source_home/.claude.json" "$sandbox_claude_state"
      ${pkgs.util-linux}/bin/mount -o remount,bind,ro "$sandbox_claude_state"
      has_claude_state=1
    fi

    ${pkgs.util-linux}/bin/mount --bind "$staged_home" "$source_home"
    mkdir -p "$source_home/.claude"
    ${pkgs.util-linux}/bin/mount --bind "$sandbox_claude" "$source_home/.claude"
    ${pkgs.util-linux}/bin/mount -o remount,bind,ro "$source_home/.claude"
    if [ "$has_claude_state" -eq 1 ]; then
      touch "$source_home/.claude.json"
      ${pkgs.util-linux}/bin/mount --bind \
        "$sandbox_claude_state" "$source_home/.claude.json"
      ${pkgs.util-linux}/bin/mount -o remount,bind,ro "$source_home/.claude.json"
    fi

    ${pkgs.util-linux}/bin/mount -t tmpfs -o mode=0700 \
      tmpfs "$XDG_RUNTIME_DIR"
    ${pkgs.util-linux}/bin/mount -t tmpfs -o mode=0555 tmpfs /proc
    ${pkgs.util-linux}/bin/mount -t sysfs sysfs /sys
    cd "$sandbox_repo"
    exec ${pkgs.util-linux}/bin/setpriv \
      --bounding-set=-all \
      --inh-caps=-all \
      --ambient-caps=-all \
      --no-new-privs \
      ${pkgs.python3}/bin/python3 -B scripts/sync_codex.py
  '';

  syncScript = pkgs.writeShellApplication {
    name = "ai-client-config-codex-sync";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.git
      pkgs.python3
      pkgs.util-linux
    ];
    text = ''
      remote="''${AI_CLIENT_CONFIG_REMOTE-https://github.com/jonathanmoregard/ai-client-config.git}"
      ref="''${AI_CLIENT_CONFIG_REF-main}"
      render_timeout="''${AI_CLIENT_CONFIG_SYNC_TIMEOUT_SECONDS-600}"
      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/ai-client-config-sync"
      failure_file="$state_dir/last-failure"
      run_dir=""
      publish_started=0
      stage="validate"
      managed_paths=(
        ".codex/config.toml"
        ".codex/rules"
        ".codex/scripts"
        ".codex/hooks"
        ".codex/hooks.json"
        ".codex/mcps"
        ".codex/plugins"
        ".codex/agents"
        ".codex/claude-setup-mirror"
        ".codex/AGENTS.md"
        ".codex/skills"
        ".agents/plugins"
        "plugins/claude-mirror"
      )

      mkdir -p "$state_dir"

      finish() {
        status=$?
        trap - EXIT
        if [ "$status" -ne 0 ] && [ "$publish_started" -eq 1 ]; then
          failed_stage="$stage"
          rollback_failed=0
          for index in "''${!managed_paths[@]}"; do
            relative="''${managed_paths[$index]}"
            target="$HOME/$relative"
            case "$relative" in
              ".agents/plugins"|"plugins/claude-mirror")
                find "$target" -mindepth 1 -maxdepth 1 \
                  -exec rm -rf -- {} + || rollback_failed=1
                if [ -e "$run_dir/backup/$index.present" ]; then
                  cp -a -- "$run_dir/backup/$index.value/." "$target/" \
                    || rollback_failed=1
                fi
                ;;
              *)
                rm -rf -- "$target" || rollback_failed=1
                if [ -e "$run_dir/backup/$index.present" ]; then
                  mkdir -p "$(dirname "$target")"
                  cp -a -- "$run_dir/backup/$index.value" "$target" \
                    || rollback_failed=1
                fi
                ;;
            esac
          done
          if [ "$rollback_failed" -ne 0 ]; then
            stage="$failed_stage-rollback"
            status=70
          fi
        fi
        if [ -n "$run_dir" ] && [ -d "$run_dir" ]; then
          rm -rf -- "$run_dir"
        fi
        if [ "$status" -eq 0 ]; then
          rm -f -- "$failure_file"
        else
          failure_tmp="$failure_file.tmp.$$"
          {
            printf 'timestamp=%s\n' "$(date --iso-8601=seconds)"
            printf 'stage=%s\n' "$stage"
            printf 'status=%s\n' "$status"
            printf '%s\n' \
              'inspect=journalctl --user -u ai-client-config-codex-sync.service -n 100'
          } > "$failure_tmp"
          mv -f -- "$failure_tmp" "$failure_file"
        fi
        exit "$status"
      }
      trap finish EXIT

      if [ -z "$remote" ] || [ -z "$ref" ]; then
        echo "ai-client-config sync: remote and ref must be non-empty" >&2
        exit 64
      fi
      case "$render_timeout" in
        *[!0-9]*|0|"")
          echo "ai-client-config sync: timeout must be a positive integer" >&2
          exit 64
          ;;
      esac
      if [ -z "''${XDG_RUNTIME_DIR-}" ] || [ ! -d "$XDG_RUNTIME_DIR" ]; then
        echo "ai-client-config sync: XDG_RUNTIME_DIR is unavailable" >&2
        exit 69
      fi
      runtime_root="$XDG_RUNTIME_DIR/ai-client-config-sync"

      clone_args=(
        --quiet
        --depth=1
        --single-branch
        --branch "$ref"
      )
      remote_normalized="''${remote,,}"
      if [[ "$remote" == file://* ]]; then
          if [ "''${AI_CLIENT_CONFIG_ALLOW_FILE_REMOTE-}" != "1" ]; then
            echo "ai-client-config sync: file remote requires explicit test adapter" >&2
            exit 64
          fi
          clone_args=(-c protocol.file.allow=always clone "''${clone_args[@]}")
      elif [[ "$remote_normalized" =~ ^https://([^/@]+@)?github[.]com(:443)?(/|$) ]]; then
          # This service deliberately cannot see the user's Git config under
          # ProtectHome=tmpfs. Use gh's existing desktop-keyring credential
          # explicitly, and scope the helper to github.com so no other remote
          # can receive it. Environment tokens would shadow that keyring.
          unset GH_TOKEN GITHUB_TOKEN
          export GH_CONFIG_DIR="$HOME/.config/gh"
          stage="authenticate"
          if ! ${lib.getExe pkgs.gh} auth token --hostname github.com \
            >/dev/null 2>&1; then
            echo "ai-client-config sync: GitHub authentication unavailable; run 'gh auth login --hostname github.com --git-protocol https' in your desktop session" >&2
            exit 69
          fi
          clone_args=(
            -c credential.helper=
            -c "credential.https://github.com.helper=!${lib.getExe pkgs.gh} auth git-credential"
            clone
            "''${clone_args[@]}"
          )
      else
          # Never inherit a system-wide credential helper for an arbitrary
          # override remote. GitHub gets the only helper above, host-scoped.
          clone_args=(-c credential.helper= clone "''${clone_args[@]}")
      fi

      stage="prepare"
      mkdir -p "$runtime_root"
      run_dir=$(mktemp -d "$runtime_root/run.XXXXXX")

      stage="clone"
      export GIT_TERMINAL_PROMPT=0
      if timeout --signal=TERM --kill-after=10 120 \
        git "''${clone_args[@]}" -- "$remote" "$run_dir/repo"; then
        :
      else
        status=$?
        echo "ai-client-config sync: clone failed with status $status" >&2
        exit "$status"
      fi

      commit=$(git -C "$run_dir/repo" rev-parse --verify HEAD)
      renderer="$run_dir/repo/scripts/sync_codex.py"
      if [ ! -f "$renderer" ]; then
        stage="validate-source"
        echo "ai-client-config sync: scripts/sync_codex.py missing at $commit" >&2
        exit 66
      fi

      stage="snapshot"
      mkdir -p "$run_dir/backup"
      staged_home="$run_dir/staged-home"
      mkdir -p "$staged_home"
      for index in "''${!managed_paths[@]}"; do
        relative="''${managed_paths[$index]}"
        target="$HOME/$relative"
        if [ -e "$target" ] || [ -L "$target" ]; then
          touch "$run_dir/backup/$index.present"
          cp -a -- "$target" "$run_dir/backup/$index.value"
          mkdir -p "$(dirname "$staged_home/$relative")"
          cp -a -- "$target" "$staged_home/$relative"
        fi
      done
      mkdir -p \
        "$staged_home/.codex" \
        "$staged_home/.agents/plugins" \
        "$staged_home/plugins/claude-mirror"

      stage="render"
      echo "ai-client-config sync: rendering ref=$ref commit=$commit"
      if timeout --foreground --signal=TERM --kill-after=2s "$render_timeout" \
        unshare --user --map-root-user --mount --pid --fork --kill-child=KILL --net --ipc --uts \
          ${renderInNamespace} \
          "$HOME" "$staged_home" "$run_dir/repo"; then
        :
      else
        status=$?
        echo "ai-client-config sync: renderer failed with status $status" >&2
        exit "$status"
      fi

      stage="publish"
      publish_started=1
      for index in "''${!managed_paths[@]}"; do
        relative="''${managed_paths[$index]}"
        source="$staged_home/$relative"
        target="$HOME/$relative"
        case "$relative" in
          ".agents/plugins"|"plugins/claude-mirror")
            find "$target" -mindepth 1 -maxdepth 1 \
              -exec rm -rf -- {} +
            if [ -e "$source" ]; then
              cp -a -- "$source/." "$target/"
            fi
            ;;
          *)
            rm -rf -- "$target"
            if [ -e "$source" ] || [ -L "$source" ]; then
              mkdir -p "$(dirname "$target")"
              cp -a -- "$source" "$target"
            fi
            ;;
        esac
      done

      stage="record"
      success_tmp="$state_dir/last-success.tmp.$$"
      {
        printf 'timestamp=%s\n' "$(date --iso-8601=seconds)"
        printf 'commit=%s\n' "$commit"
        printf 'ref=%s\n' "$ref"
      } > "$success_tmp"
      mv -f -- "$success_tmp" "$state_dir/last-success"
      stage="complete"
      echo "ai-client-config sync: complete commit=$commit"
    '';
  };

  failureNotify = pkgs.writeShellApplication {
    name = "ai-client-config-codex-sync-failure-notify";
    runtimeInputs = [ pkgs.libnotify ];
    text = ''
      failure_file="''${XDG_STATE_HOME:-$HOME/.local/state}/ai-client-config-sync/last-failure"
      details="failure details unavailable"
      if [ -r "$failure_file" ]; then
        details=$(tr '\n' ' ' < "$failure_file")
      fi
      echo "ai-client-config sync failed: $details" >&2
      notify-send --urgency=critical \
        "Claude to Codex sync failed" \
        "See $failure_file" || true
    '';
  };
in
{
  # systemd's bind paths require targets to exist before its mount
  # namespace is created. Make renderer-owned roots available on fresh hosts.
  home.activation.ensureAiClientConfigSyncDirs =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p \
        "$HOME/.codex" \
        "$HOME/.agents/plugins" \
        "$HOME/plugins/claude-mirror" \
        "$HOME/.local/state/ai-client-config-sync"
    '';

  home.packages = [ syncScript ];

  systemd.user.services.ai-client-config-codex-sync = {
    Unit = {
      Description = "Render latest Claude config into Codex";
      After = [ "default.target" ];
      OnFailure = [ "ai-client-config-codex-sync-failure-notify.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${syncScript}/bin/ai-client-config-codex-sync";
      Environment = "PYTHONDONTWRITEBYTECODE=1";
      Nice = 10;
      IOSchedulingClass = "idle";
      TimeoutStartSec = "15min";
      RuntimeDirectory = "ai-client-config-sync";
      RuntimeDirectoryMode = "0700";

      NoNewPrivileges = "yes";
      PrivateTmp = "yes";
      ProtectSystem = "strict";
      ProtectHome = "tmpfs";
      # gh keeps the token in Secret Service. Expose only its config metadata
      # and the user-bus socket needed for the pre-render credential lookup.
      # renderInNamespace mounts a fresh tmpfs over XDG_RUNTIME_DIR, so the
      # fetched repository and its renderer still cannot reach that socket.
      BindReadOnlyPaths = lib.concatStringsSep " " [
        "-%h/.claude"
        "-%h/.claude.json"
        "-%h/.config/gh"
        "-%t/bus"
      ];
      BindPaths = lib.concatStringsSep " " [
        "%h/.codex"
        "%h/.agents/plugins"
        "%h/plugins/claude-mirror"
        "%h/.local/state/ai-client-config-sync"
      ];
      InaccessiblePaths = lib.concatStringsSep " " [
        "-%h/.codex/auth.json"
        "-%h/.codex/sessions"
        "-%h/.codex/history.jsonl"
        "-%h/.codex/session_index.jsonl"
        "-%h/.codex/shell_snapshots"
        "-%h/.codex/tasks"
        "-%h/.codex/tmp"
        "-%h/.codex/.tmp"
        "-%h/.codex/cache"
        "-%h/.codex/log"
        "-%h/.codex/mcp-oauth-locks"
        "-%h/.codex/goals_1.sqlite"
        "-%h/.codex/goals_1.sqlite-shm"
        "-%h/.codex/goals_1.sqlite-wal"
        "-%h/.codex/logs_2.sqlite"
        "-%h/.codex/logs_2.sqlite-shm"
        "-%h/.codex/logs_2.sqlite-wal"
        "-%h/.codex/memories"
        "-%h/.codex/memories_1.sqlite"
        "-%h/.codex/memories_1.sqlite-shm"
        "-%h/.codex/memories_1.sqlite-wal"
        "-%h/.codex/state_5.sqlite"
        "-%h/.codex/state_5.sqlite-shm"
        "-%h/.codex/state_5.sqlite-wal"
      ];
      ProtectKernelTunables = "yes";
      ProtectKernelModules = "yes";
      ProtectControlGroups = "yes";
      RestrictSUIDSGID = "yes";
      LockPersonality = "yes";
      MemoryMax = "1G";
      TasksMax = 256;
    };
  };

  systemd.user.services.ai-client-config-codex-sync-failure-notify = {
    Unit.Description = "Report Claude to Codex sync failure";
    Service = {
      Type = "oneshot";
      ExecStart = "${failureNotify}/bin/ai-client-config-codex-sync-failure-notify";
    };
  };

  systemd.user.timers.ai-client-config-codex-sync = {
    Unit.Description = "Refresh Codex from latest Claude config hourly";
    Timer = {
      OnBootSec = "5min";
      OnCalendar = "hourly";
      Persistent = true;
      AccuracySec = "5min";
      RandomizedDelaySec = "5min";
      Unit = "ai-client-config-codex-sync.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
