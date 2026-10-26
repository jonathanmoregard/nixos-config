{ lib, pkgs, ... }:
let
  networkOnline = import ./network-online-script.nix { inherit pkgs; };
  ghHost = import ./gh-host-token.nix { inherit pkgs; };
  credentialHelper = "${ghHost.credentialHelper}/bin/gh-app-credential";

  renderInNamespace = pkgs.writeShellScript "ai-client-config-render-isolated" ''
    set -euo pipefail
    live_home="$1"
    source_home="$2"
    staged_home="$3"
    repo="$4"
    sandbox_repo=/tmp/ai-client-config-repo
    sandbox_claude=/tmp/ai-client-config-claude
    sandbox_repos=/tmp/ai-client-config-repos

    mkdir -p "$sandbox_repo" "$sandbox_claude"
    ${pkgs.util-linux}/bin/mount --bind "$repo" "$sandbox_repo"
    ${pkgs.util-linux}/bin/mount --bind "$source_home/.claude" "$sandbox_claude"
    ${pkgs.util-linux}/bin/mount -o remount,bind,ro "$sandbox_claude"

    has_repos=0
    if [ -d "$source_home/Repos" ]; then
      mkdir -p "$sandbox_repos"
      ${pkgs.util-linux}/bin/mount --bind "$source_home/Repos" "$sandbox_repos"
      ${pkgs.util-linux}/bin/mount -o remount,bind,ro "$sandbox_repos"
      has_repos=1
    fi

    ${pkgs.util-linux}/bin/mount --bind "$staged_home" "$live_home"
    mkdir -p "$live_home/.claude"
    ${pkgs.util-linux}/bin/mount --bind "$sandbox_claude" "$live_home/.claude"
    ${pkgs.util-linux}/bin/mount -o remount,bind,ro "$live_home/.claude"
    if [ "$has_repos" -eq 1 ]; then
      mkdir -p "$live_home/Repos"
      ${pkgs.util-linux}/bin/mount --bind "$sandbox_repos" "$live_home/Repos"
      ${pkgs.util-linux}/bin/mount -o remount,bind,ro "$live_home/Repos"
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
      pkgs.rsync
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
      # Listed directories are authoritative mirror output; omitted children
      # are pruned. Native runtime locations are excluded below.
      managed_paths=(
        ".codex/config.toml"
        ".codex/rules"
        ".codex/scripts"
        ".codex/hooks"
        ".codex/hooks.json"
        ".codex/mcps"
        ".codex/plugins/claude-mirror"
        ".codex/agents"
        ".codex/claude-setup-mirror"
        ".codex/AGENTS.md"
        ".codex/skills"
        ".agents/plugins"
        "plugins/claude-mirror"
      )

      # Only these generated paths belong to the mirror. Everything else,
      # including Codex's bundled skills and installed plugins, stays outside it.
      sync_filters=(
        --exclude="/.codex/skills/.system/***"
        # Active sessions cache these immutable hook commands and runtimes.
        --filter="P /.codex/hooks/claude-mirror/***"
      )
      for relative in "''${managed_paths[@]}"; do
        parent=$(dirname "$relative")
        while [ "$parent" != "." ]; do
          sync_filters+=( --include="/$parent/" )
          parent=$(dirname "$parent")
        done
        sync_filters+=( --include="/$relative" --include="/$relative/***" --include="/$relative.bak-*" )
      done
      sync_filters+=( --exclude="*" )

      sync_tree() {
        local source_root="$1" target_root="$2"
        shift 2
        # Copy payloads before the entry points that reference them, including
        # on first installation. Then update those entry points and prune.
        # Keep private directory permissions and file executable bits.
        rsync -rltE --checksum --omit-dir-times \
          --exclude="/.codex/config.toml" \
          --exclude="/.codex/hooks.json" \
          --exclude="/.agents/plugins/marketplace.json" \
          --exclude="/plugins/claude-mirror/.codex-plugin/plugin.json" \
          --exclude="/plugins/claude-mirror/.mcp.json" \
          --exclude="/plugins/claude-mirror/hooks.json" \
          "$@" "''${sync_filters[@]}" -- "$source_root/" "$target_root/" || return
        rsync -rltE --checksum --omit-dir-times --delete-after \
          "$@" "''${sync_filters[@]}" -- "$source_root/" "$target_root/"
      }

      mkdir -p "$state_dir"

      finish() {
        status=$?
        trap - EXIT
        if [ "$status" -ne 0 ] && [ "$publish_started" -eq 1 ]; then
          failed_stage="$stage"
          if ! sync_tree "$run_dir/backup" "$HOME"; then
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
          # ProtectHome=tmpfs. Name the GitHub App host-token helper
          # explicitly (home/gh-host-token.nix; only that token's directory
          # is bound in), scoped to github.com so no other remote can receive
          # it. It fails closed: no token, no clone, and no keyring fallback.
          # useHttpPath hands the helper path=OWNER/NAME.git so it picks that
          # owner's installation token (personal or org); the probe asks for
          # exactly the path the clone will.
          stage="authenticate"
          probe_path="''${remote#*://}"
          probe_path="''${probe_path#*/}"
          if ! printf 'protocol=https\nhost=github.com\npath=%s\n\n' "$probe_path" \
            | ${credentialHelper} get >/dev/null; then
            echo "ai-client-config sync: GitHub App host token unavailable; run 'systemctl --user start gh-token.service' and check 'journalctl --user -u gh-token.service'" >&2
            exit 69
          fi
          clone_args=(
            -c credential.helper=
            -c "credential.https://github.com.helper=${credentialHelper}"
            -c credential.https://github.com.useHttpPath=true
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

      # Materialize only explicit renderer entry points. Nested symlinks stay
      # symlinks, so they cannot pull hidden credentials into the snapshot.
      stage="snapshot-source"
      source_home="$run_dir/source-home"
      source_entries=(
        ".claude/CLAUDE.md"
        ".claude/settings.json"
        ".claude/mcp-servers.json"
        ".claude/plugins/installed_plugins.json"
        ".claude/plugins/known_marketplaces.json"
        ".claude/plugins/cache"
        ".claude.json"
      )
      source_collections=(
        ".claude/skills"
        ".claude/commands"
        ".claude/agents"
        ".claude/hooks"
        ".claude/mcps"
      )

      snapshot_entry() {
        local relative="$1"
        local source="$HOME/$relative"
        local resolved target
        if [ ! -e "$source" ] && [ ! -L "$source" ]; then
          return
        fi
        if ! resolved=$(realpath -e -- "$source"); then
          echo "ai-client-config sync: unresolved source $relative" >&2
          exit 66
        fi
        target="$source_home/$relative"
        mkdir -p "$(dirname "$target")"
        if [ -d "$resolved" ]; then
          mkdir -p "$target"
          cp -a --no-preserve=ownership -- "$resolved/." "$target/"
        else
          cp -a --no-preserve=ownership -- "$resolved" "$target"
        fi
      }

      # Resolve the collection itself, then enumerate its entries and
      # materialize each one through snapshot_entry. A collection that is a
      # symlink to a directory is still a collection: it must be walked, not
      # copied wholesale. `cp -a` implies `-d`, so a wholesale copy preserves
      # every entry that is a symlink as a symlink, and those targets are not
      # in the renderer's namespace — the farm would arrive dangling. Entries
      # are addressed by "$relative/<basename>" rather than by stripping
      # $HOME, because the resolved collection may sit outside $HOME.
      snapshot_collection() {
        local relative="$1"
        local source="$HOME/$relative"
        local resolved entry
        if [ ! -e "$source" ] && [ ! -L "$source" ]; then
          return
        fi
        if ! resolved=$(realpath -e -- "$source"); then
          echo "ai-client-config sync: unresolved source $relative" >&2
          exit 66
        fi
        if [ ! -d "$resolved" ]; then
          snapshot_entry "$relative"
          return
        fi
        # find's exit status is invisible through process substitution, so an
        # unreadable collection would enumerate as empty, the snapshot would
        # hold nothing for it, and the publish step would then prune every
        # rendered entry under it — a silent wipe reported as success. Write
        # the listing to a file so the failure is observable.
        local listing="$run_dir/collection-listing"
        if ! find -P "$resolved" -mindepth 1 -maxdepth 1 -print0 > "$listing"; then
          echo "ai-client-config sync: cannot enumerate $relative" >&2
          exit 66
        fi
        mkdir -p "$source_home/$relative"
        while IFS= read -r -d "" entry; do
          snapshot_entry "$relative/''${entry##*/}"
        done < "$listing"
      }

      mkdir -p "$source_home/.claude"
      for relative in "''${source_entries[@]}"; do
        snapshot_entry "$relative"
      done
      for relative in "''${source_collections[@]}"; do
        snapshot_collection "$relative"
      done

      # Generated wrappers retain absolute install paths. Copy only enabled
      # plugin roots under ~/Repos and recreate that sparse path read-only in
      # the renderer namespace. Other home paths remain hidden.
      settings_file="$source_home/.claude/settings.json"
      installed_file="$source_home/.claude/plugins/installed_plugins.json"
      enabled_plugin_paths="$run_dir/enabled-plugin-paths"
      if [ -f "$settings_file" ] && [ -f "$installed_file" ]; then
        if ! ${lib.getExe pkgs.jq} -r --slurpfile settings "$settings_file" '
          (.plugins // {}) as $plugins
          | (($settings[0].enabledPlugins // {}) | to_entries[])
          | select(.value == true)
          | .key as $id
          | (($plugins[$id] // []) | last | .installPath // empty)
        ' "$installed_file" | sort -u > "$enabled_plugin_paths"; then
          echo "ai-client-config sync: invalid plugin metadata" >&2
          exit 66
        fi

        while IFS= read -r plugin_path; do
          [ -n "$plugin_path" ] || continue
          plugin_normalized=$(realpath -ms -- "$plugin_path")
          case "$plugin_normalized" in
            "$HOME/.claude"|"$HOME/.claude/"*)
              ;;
            "$HOME/Repos")
              echo "ai-client-config sync: plugin path cannot expose all of ~/Repos" >&2
              exit 66
              ;;
            "$HOME/Repos/"*)
              if ! repos_root=$(realpath -e -- "$HOME/Repos") ||
                ! plugin_resolved=$(realpath -e -- "$plugin_normalized"); then
                echo "ai-client-config sync: unresolved plugin path $plugin_path" >&2
                exit 66
              fi
              case "$plugin_resolved" in
                "$repos_root"|"$repos_root/"*)
                  snapshot_entry "''${plugin_normalized#"$HOME/"}"
                  ;;
                *)
                  echo "ai-client-config sync: plugin path escapes ~/Repos: $plugin_path" >&2
                  exit 66
                  ;;
              esac
              ;;
            "$HOME"|"$HOME/"*)
              echo "ai-client-config sync: unsupported hidden plugin path $plugin_path" >&2
              exit 66
              ;;
            *)
              ;;
          esac
        done < "$enabled_plugin_paths"
      fi
      chmod -R u+w -- "$source_home"

      stage="snapshot"
      mkdir -p "$run_dir/backup"
      staged_home="$run_dir/staged-home"
      mkdir -p "$staged_home"
      sync_tree "$HOME" "$run_dir/backup"
      # These are merge inputs, not generated output to carry forward. Render
      # every generated directory from scratch so omitted files become stale.
      for relative in \
        .codex/config.toml \
        .codex/rules/default.rules \
        .agents/plugins/marketplace.json; do
        if [ -f "$run_dir/backup/$relative" ]; then
          mkdir -p "$(dirname "$staged_home/$relative")"
          cp -a -- "$run_dir/backup/$relative" "$staged_home/$relative"
        fi
      done
      mkdir -p \
        "$staged_home/.codex" \
        "$staged_home/.agents/plugins" \
        "$staged_home/plugins/claude-mirror"
      if [ -f "$source_home/.claude.json" ]; then
        cp -a --no-preserve=ownership -- \
          "$source_home/.claude.json" "$staged_home/.claude.json"
      fi

      stage="render"
      echo "ai-client-config sync: rendering ref=$ref commit=$commit"
      if timeout --foreground --signal=TERM --kill-after=2s "$render_timeout" \
        unshare --user --map-root-user --mount --pid --fork --kill-child=KILL --net --ipc --uts \
          ${renderInNamespace} \
          "$HOME" "$source_home" "$staged_home" "$run_dir/repo"; then
        :
      else
        status=$?
        echo "ai-client-config sync: renderer failed with status $status" >&2
        exit "$status"
      fi

      stage="publish"
      publish_started=1
      # Renderer backups are not desired output. Hiding them only on the
      # sender lets the same final prune remove old backups on the receiver.
      sync_tree "$staged_home" "$HOME" --filter='H *.bak-*'

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
    runtimeInputs = [ pkgs.libnotify networkOnline ];
    text = ''
      failure_file="''${XDG_STATE_HOME:-$HOME/.local/state}/ai-client-config-sync/last-failure"
      details="failure details unavailable"
      if [ -r "$failure_file" ]; then
        details=$(tr '\n' ' ' < "$failure_file")
      fi
      echo "ai-client-config sync failed: $details" >&2
      # Offline → no toast; see home/network-online-script.nix.
      if ! network-online; then
        echo "network offline — desktop notification suppressed" >&2
        exit 0
      fi
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
      # GitHub credentials: only the App host-token directory (a directory,
      # not the file, so the timer's atomic rename stays visible). No gh
      # config and no user bus: the founder's keyring is out of reach.
      # Trusted wrapper snapshots explicit Claude config entry points and
      # enabled plugin roots. renderInNamespace masks the live home and runtime
      # directory, then exposes only the sparse source snapshot read-only.
      BindReadOnlyPaths = lib.concatStringsSep " " [
        "-%h/.claude"
        "-%h/.claude.json"
        "-%h/.cache/gh-tokens/host"
        "-%h/Repos"
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
