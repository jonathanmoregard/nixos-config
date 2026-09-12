{ pkgs, ... }:
let
  fetchScript = pkgs.writeShellApplication {
    name = "nixos-config-fetch";
    runtimeInputs = with pkgs; [
      coreutils
      git
    ];
    text = ''
      set -euo pipefail

      git_bin="''${NIXOS_CONFIG_FETCH_GIT_BIN:-${pkgs.git}/bin/git}"
      anchor="''${NIXOS_CONFIG_FETCH_ANCHOR:-$HOME/Repos/nixos-config-worktrees/main}"
      remote="''${NIXOS_CONFIG_FETCH_REMOTE:-origin}"
      branch="''${NIXOS_CONFIG_FETCH_BRANCH:-main}"
      state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/nixos-config-fetch"
      last_success="$state_dir/last-success"

      case "$remote" in
        ""|-*|*[!A-Za-z0-9._-]*)
          printf 'nixos-config-fetch: invalid remote name: %s\n' "$remote" >&2
          exit 2
          ;;
      esac
      if ! "$git_bin" check-ref-format "refs/heads/$branch" >/dev/null; then
        printf 'nixos-config-fetch: invalid branch name: %s\n' "$branch" >&2
        exit 2
      fi
      if [ ! -d "$anchor" ]; then
        printf 'nixos-config-fetch: anchor missing: %s\n' "$anchor" >&2
        exit 2
      fi

      "$git_bin" -c safe.directory="$anchor" -C "$anchor" \
        rev-parse --is-inside-work-tree >/dev/null
      "$git_bin" -c safe.directory="$anchor" -C "$anchor" \
        remote get-url "$remote" >/dev/null

      # Fetch remote-tracking ref only. Never move refs/heads/main: several
      # linked worktrees may share it while each has an independent index.
      "$git_bin" -c safe.directory="$anchor" -C "$anchor" fetch \
        --no-tags \
        --no-write-fetch-head \
        "$remote" \
        "+refs/heads/$branch:refs/remotes/$remote/$branch"
      commit=$("$git_bin" -c safe.directory="$anchor" -C "$anchor" \
        rev-parse --verify "refs/remotes/$remote/$branch^{commit}")

      mkdir -p "$state_dir"
      success_tmp=$(mktemp "$state_dir/.last-success.XXXXXX")
      cleanup() {
        rm -f "$success_tmp"
      }
      trap cleanup EXIT
      printf 'timestamp=%s\ncommit=%s\n' \
        "$(date -Iseconds)" "$commit" > "$success_tmp"
      mv -f "$success_tmp" "$last_success"
      printf 'NixOS config fetch completed: %s/%s=%s\n' \
        "$remote" "$branch" "$commit"
    '';
  };

  failureNotifyScript = pkgs.writeShellApplication {
    name = "nixos-config-fetch-failure-notify";
    runtimeInputs = [ pkgs.libnotify ];
    text = ''
      message="NixOS config fetch failed — inspect: journalctl --user -u nixos-config-fetch.service"
      printf '%s\n' "$message"
      notify-send --urgency=critical "NixOS config fetch failed" "$message" || true
    '';
  };
in
{
  home.packages = [ fetchScript ];

  systemd.user.services = {
    nixos-config-fetch = {
      Unit = {
        Description = "Fetch latest NixOS config origin/main";
        OnFailure = [ "nixos-config-fetch-failure-notify.service" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${fetchScript}/bin/nixos-config-fetch";
        TimeoutStartSec = 180;
      };
    };

    nixos-config-fetch-failure-notify = {
      Unit.Description = "Notify when NixOS config fetch fails";
      Service = {
        Type = "oneshot";
        ExecStart = "${failureNotifyScript}/bin/nixos-config-fetch-failure-notify";
      };
    };
  };

  systemd.user.timers.nixos-config-fetch = {
    Unit.Description = "Fetch NixOS config origin/main every 30 minutes";
    Timer = {
      OnCalendar = "*:0/30";
      AccuracySec = "5min";
      RandomizedDelaySec = "5min";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
