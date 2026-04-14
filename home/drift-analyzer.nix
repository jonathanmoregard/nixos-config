{ pkgs, ... }:
let
  analyzerScript = pkgs.writeShellScript "nixos-drift-analyzer" ''
    set -euo pipefail

    LOG_DIR="$HOME/.local/share/nixos-drift-analyzer"
    mkdir -p "$LOG_DIR"
    LATEST="$LOG_DIR/latest.md"
    RUNLOG="$LOG_DIR/run.log"

    log() { echo "$(date -Iseconds): $*" >> "$RUNLOG"; }

    # claude-code is in home.packages — use it directly
    CLAUDE="${pkgs.claude-code}/bin/claude"
    if [ ! -x "$CLAUDE" ]; then
      log "claude not found at $CLAUDE, skipping"
      exit 0
    fi

    log "starting drift analysis"

    # Live state: imperative installs
    IMPERATIVE=$(${pkgs.nix}/bin/nix-env --query 2>/dev/null | grep -v '^$' || true)

    # Live state: manually dropped binaries
    LOCAL_BIN=$(ls "$HOME/.local/bin" 2>/dev/null | tr '\n' ' ' || true)

    # Inline key nix config files (skip large/generated ones)
    CONFIG=""
    for f in /etc/nixos/flake.nix \
              /etc/nixos/home/jonathan.nix \
              /etc/nixos/home/jonathan-linux.nix \
              /etc/nixos/home/desktop-apps.nix \
              /etc/nixos/home/cinnamon.nix \
              /etc/nixos/modules/nixos/desktop.nix \
              /etc/nixos/hosts/vm/default.nix; do
      if [ -f "$f" ]; then
        CONFIG+="
=== ''${f#/etc/nixos/} ===
$(cat "$f")
"
      fi
    done

    PROMPT="You are a NixOS config drift analyzer running on a live NixOS VM (Linux Mint 22.2 / Cinnamon mirror).
Your goal: find things that will be LOST on the next nixos-rebuild and draft the exact Nix code to capture them.

## Live system state

nix-env imperative installs (lost on rebuild):
''${IMPERATIVE:-none}

~/.local/bin (manually placed, may need home.packages):
''${LOCAL_BIN:-empty}

## Current NixOS config
$CONFIG

## Instructions

1. Compare live state to what is declared in the config.
2. Also flag static patterns that commonly cause drift:
   - ~/.ssh/config, ~/.gnupg/, ~/.config/* paths not managed by home.file or programs.*
   - Service state dirs not persisted (/var/lib/*, ~/.local/share/*)
   - PATH entries or env vars set imperatively that belong in home.sessionVariables
   - TODOs / manual-step comments that could be automated
   - Incomplete autostart, dconf, or MIME declarations
3. For each gap, write the exact Nix snippet to fix it (file + attribute path).
4. Be conservative — only flag things you are confident about from what is visible here.
5. Output a markdown report with:
   - ## Drift Report $(date +%Y-%m-%d)
   - One bullet per finding: problem, then nix code block with the fix
   - If nothing to report: '## No drift detected $(date +%Y-%m-%d)'"

    "$CLAUDE" --print "$PROMPT" > "$LATEST" 2>> "$RUNLOG"
    log "done — report at $LATEST"
  '';
in
{
  home.packages = [ pkgs.claude-code ];

  systemd.user.services.nixos-drift-analyzer = {
    Unit.Description = "NixOS config drift analyzer";
    Service = {
      Type = "oneshot";
      ExecStart = "${analyzerScript}";
    };
  };

  systemd.user.timers.nixos-drift-analyzer = {
    Unit.Description = "NixOS drift analyzer — hourly";
    Timer = {
      OnCalendar = "hourly";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
